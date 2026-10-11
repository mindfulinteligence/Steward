defmodule Acs.Specs.AuditorTest do
  @moduledoc "LLM approve/reject must change document/spec status (like memories)."
  use ExUnit.Case, async: false

  alias Acs.Specs.Auditor
  alias Acs.Specs.Entry
  alias Acs.Specs.Loader

  setup do
    tmp = Path.join(System.tmp_dir!(), "acs_specs_auditor_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    previous = Application.get_env(:steward_acs, Acs.Specs.Loader, [])

    Application.put_env(
      :steward_acs,
      Acs.Specs.Loader,
      Keyword.put(previous, :specs_path, tmp)
    )

    on_exit(fn ->
      Application.put_env(:steward_acs, Acs.Specs.Loader, previous)
      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "apply_evaluation approve sets status approved and persists audit fields" do
    entry =
      Entry.from_map(%{
        "app" => "docs",
        "id" => "policy/refunds",
        "status" => "proposed",
        "title" => "Refund policy for chat support agents",
        "document_type" => "policy",
        "content" =>
          "Customers may request a refund within 30 days of purchase when the product was unused. Escalations go to finance@"
      })

    assert :ok = Loader.save(entry)

    result =
      Auditor.apply_evaluation(entry, %{
        "recommendation" => "approve",
        "quality_score" => 4,
        "reasoning" => "Clear policy useful for chat agents"
      })

    assert result.audit_verdict == "approve"
    assert result.status == "approved"

    assert {:ok, loaded} = Loader.load("docs", "policy/refunds")
    assert loaded.status == "approved"
    assert loaded.approved_by == "llm"
    assert loaded.audit_verdict == "approve"
    assert loaded.quality_score == 4
  end

  test "apply_evaluation reject sets status rejected" do
    entry =
      Entry.from_map(%{
        "app" => "docs",
        "id" => "scratch/todo",
        "status" => "proposed",
        "title" => "Document",
        "document_type" => "knowledge",
        "content" => "TODO"
      })

    assert :ok = Loader.save(entry)

    result =
      Auditor.apply_evaluation(entry, %{
        "recommendation" => "reject",
        "quality_score" => 1,
        "reasoning" => "Placeholder junk"
      })

    assert result.status == "rejected"
    assert {:ok, loaded} = Loader.load("docs", "scratch/todo")
    assert loaded.status == "rejected"
    assert loaded.audit_verdict == "reject"
  end

  test "apply_evaluation human_review keeps proposed and parks via audit_verdict" do
    entry =
      Entry.from_map(%{
        "app" => "docs",
        "id" => "policy/edge",
        "status" => "proposed",
        "title" => "Edge-case refund handling for disputed charges",
        "document_type" => "policy",
        "content" =>
          "When a chargeback is opened, pause automated refunds and route to human review within 24 hours."
      })

    assert :ok = Loader.save(entry)

    result =
      Auditor.apply_evaluation(entry, %{
        "recommendation" => "human_review",
        "quality_score" => 3,
        "reasoning" => "Ambiguous scope"
      })

    assert result.status == "proposed"
    assert result.audit_verdict == "human_review"
    assert {:ok, loaded} = Loader.load("docs", "policy/edge")
    assert loaded.status == "proposed"
    assert loaded.audit_verdict == "human_review"
  end

  test "audit_all fails fast on a legacy entry missing purpose instead of retrying", %{tmp: tmp} do
    entry =
      Entry.from_map(%{
        "app" => "docs",
        "id" => "legacy/no-purpose",
        "status" => "proposed",
        "title" => "Legacy spec without a purpose",
        "purpose" => "Explains why the legacy module exists and who depends on it today.",
        "invariants" => ["Callers always pass a binary id value"],
        "workflows" => ["Load the entry, then audit it once per cycle"],
        "failure_modes" => ["A missing id raises an ArgumentError"],
        "created_at" => "2020-01-01T00:00:00Z"
      })

    assert :ok = Loader.save(entry)

    # Simulate a pre-validation file by stripping the purpose from disk.
    [file] = Path.wildcard(Path.join(tmp, "**/no-purpose.yaml"))
    stripped = file |> File.read!() |> String.replace(~r/^purpose:.*\n/m, "")
    refute stripped == File.read!(file)
    File.write!(file, stripped)

    {{micros, {results, _}}, log} =
      ExUnit.CaptureLog.with_log(fn -> :timer.tc(fn -> Auditor.audit_all() end) end)

    # First backoff delay is 2s; a retry would blow well past this.
    assert micros < 1_500_000
    assert Enum.any?(results, &(&1[:id] == "legacy/no-purpose" and &1[:audit_verdict] == "error"))
    assert log =~ "Skipping docs/legacy/no-purpose"
    refute log =~ "Retrying"
  end
end

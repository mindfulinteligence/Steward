defmodule Acs.Specs.Auditor do
  @moduledoc """
  GenServer that periodically audits proposed specs/documents with an LLM.

  Same decision model as `Acs.Memory.Auditor`: approve / reject / human_review.
  Approve and reject update governance `status`; human_review parks the entry
  (keeps `proposed`) so we do not re-burn tokens every cycle.

  Also supports post-save `audit_soon/2` (mirrors `Acs.Skills.Auditor`).
  """

  use GenServer
  require Logger

  alias Acs.LLM
  alias Acs.Org
  alias Acs.Specs.Entry
  alias Acs.Specs.Loader

  @interval 60_000
  @cooling_off_seconds 30
  @max_retries 3
  @backoff_delays [2_000, 5_000, 15_000]

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def trigger_audit do
    GenServer.cast(__MODULE__, :trigger)
  end

  @doc "Queue a single-entry audit after documents_propose / specs_propose."
  def audit_soon(app, path) when is_binary(app) and is_binary(path) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:audit_one, Org.current(), app, path})
    end

    :ok
  end

  def audit_soon(_, _), do: :ok

  def audit_interval do
    Application.get_env(:steward_acs, :spec_auditor_interval, @interval)
  end

  @impl true
  def init(_opts) do
    Logger.info("[Acs.Specs.Auditor] Starting with interval: #{audit_interval()}ms")
    Acs.IdleTracker.subscribe()
    schedule_audit()
    {:ok, %{running: false, audited: MapSet.new()}}
  end

  @impl true
  def handle_info(:audit, %{running: true} = state), do: {:noreply, state}

  @impl true
  def handle_info(:activity, state) do
    Logger.debug("[Acs.Specs.Auditor] Activity detected, waking to fast cadence")
    schedule_audit()
    {:noreply, state}
  end

  @impl true
  def handle_info(:audit, state) do
    if Acs.IdleTracker.idle?() do
      Logger.debug("[Acs.Specs.Auditor] Idle, sleeping")
      schedule_audit(Acs.IdleTracker.sleep_interval_ms())
      {:noreply, state}
    else
      state = %{state | running: true}
      {_results, audited} = audit_all(state.audited)
      schedule_audit()
      {:noreply, %{state | running: false, audited: audited}}
    end
  end

  @impl true
  def handle_info({:audit_one, org, app, path}, state) do
    key = {org, app, path}
    audited = MapSet.delete(state.audited, key)

    audited =
      Org.with_current(org, fn ->
        case Loader.load(app, path) do
          {:ok, entry} ->
            case audit_one(org, entry) do
              %{app: ^app, id: ^path} -> MapSet.put(audited, key)
              _ -> audited
            end

          _ ->
            Logger.debug(
              "[Acs.Specs.Auditor] #{org}/#{app}/#{path} not found for post-save audit"
            )

            audited
        end
      end)

    {:noreply, %{state | audited: audited}}
  end

  @impl true
  def handle_cast(:trigger, %{running: true} = state) do
    Logger.debug("[Acs.Specs.Auditor] Audit already running, skipping trigger")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:trigger, state) do
    send(self(), :audit)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:audit_one, org, app, path}, state) do
    send(self(), {:audit_one, org, app, path})
    {:noreply, state}
  end

  defp schedule_audit do
    Process.send_after(self(), :audit, audit_interval())
  end

  defp schedule_audit(interval) do
    Process.send_after(self(), :audit, interval)
  end

  @doc """
  Audit proposed entries across all orgs that lack a parked audit verdict
  and are not in the in-process skip cache.
  """
  def audit_all(audited \\ MapSet.new()) do
    candidates = fetch_auditable(audited)

    Logger.info("[Acs.Specs.Auditor] Auditing #{length(candidates)} specs/documents")

    max_conc = Application.get_env(:steward_acs, :spec_auditor_max_concurrency, 5)

    results =
      candidates
      |> Task.async_stream(
        fn {org, entry} ->
          Org.with_current(org, fn -> audit_one(org, entry) end)
        end,
        max_concurrency: max_conc,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:error, reason} -> %{audit_verdict: "error", audit_reasoning: inspect(reason)}
      end)
      |> Enum.reject(&is_nil/1)

    approved =
      Enum.count(results, &(&1[:audit_verdict] == "approve" or &1[:status] == "approved"))

    rejected = Enum.count(results, &(&1[:audit_verdict] == "reject" or &1[:status] == "rejected"))
    review = Enum.count(results, &(&1[:audit_verdict] == "human_review"))

    Logger.info(
      "[Acs.Specs.Auditor] Audit complete: approved=#{approved} rejected=#{rejected} human_review=#{review}"
    )

    audited =
      Enum.reduce(results, audited, fn
        %{org: org, app: app, id: id}, acc when is_binary(app) and is_binary(id) ->
          MapSet.put(acc, {org, app, id})

        _, acc ->
          acc
      end)

    {results, audited}
  end

  defp fetch_auditable(audited) do
    cooling_off = DateTime.utc_now() |> DateTime.add(-@cooling_off_seconds, :second)

    Org.all()
    |> Enum.flat_map(fn org ->
      Org.with_current(org, fn ->
        case Loader.load_all() do
          {:ok, entries} ->
            entries
            |> Enum.filter(&(&1.status == "proposed"))
            |> Enum.reject(&already_audited?/1)
            |> Enum.reject(fn e -> MapSet.member?(audited, {org, e.app, e.id}) end)
            |> Enum.filter(&past_cooling_off?(&1, cooling_off))
            |> Enum.map(&{org, &1})

          _ ->
            []
        end
      end)
    end)
  end

  # Park human_review so we don't re-burn tokens. Re-try approve/reject if still proposed
  # (e.g. prior save failed after the LLM call).
  defp already_audited?(%Entry{audit_verdict: "human_review"}), do: true

  defp already_audited?(%Entry{audit_verdict: v}) when v in ["approve", "reject"],
    do: false

  defp already_audited?(%Entry{audited_at: at}) when is_binary(at) and at != "", do: true
  defp already_audited?(_), do: false

  defp past_cooling_off?(%Entry{created_at: nil}, _), do: false

  defp past_cooling_off?(%Entry{created_at: created_at}, threshold) do
    case DateTime.from_iso8601(created_at) do
      {:ok, dt, _} -> DateTime.compare(dt, threshold) == :lt
      _ -> false
    end
  end

  defp audit_one(org, entry) do
    case audit_with_retry(entry, @max_retries, @backoff_delays) do
      {:ok, result} ->
        Map.put(result, :org, org)

      {:error, reason} ->
        %{
          org: org,
          app: entry.app,
          id: entry.id,
          audit_verdict: "error",
          audit_reasoning: inspect(reason)
        }
    end
  end

  defp audit_with_retry(_entry, 0, _delays), do: {:error, :max_retries}

  defp audit_with_retry(entry, retries_left, [delay | rest]) do
    case LLM.evaluate_spec("#{entry.app}/#{entry.id}", entry_attrs(entry)) do
      {:ok, evaluation} ->
        {:ok, apply_evaluation(entry, evaluation)}

      {:error, :no_providers_enabled} ->
        {:error, :no_providers_enabled}

      {:error, {:all_providers_failed, _} = reason} ->
        {:error, reason}

      {:error, reason} ->
        Logger.warning(
          "[Acs.Specs.Auditor] Audit failed for #{entry.app}/#{entry.id}: #{inspect(reason)}. Retrying..."
        )

        Process.sleep(delay)
        audit_with_retry(entry, retries_left - 1, rest)
    end
  end

  defp audit_with_retry(entry, retries_left, []),
    do: audit_with_retry(entry, retries_left, @backoff_delays)

  defp entry_attrs(entry) do
    %{
      audience: entry_audience(entry),
      app: entry.app || "",
      id: entry.id || "",
      title: entry.title || "",
      purpose: entry.purpose || "",
      content: entry.content || "",
      document_type: entry.document_type,
      invariants: entry.invariants || [],
      workflows: entry.workflows || [],
      failure_modes: entry.failure_modes || [],
      tags: entry.tags || []
    }
  end

  # Documents from chat land with document_type set; code specs stay coding.
  defp entry_audience(%Entry{document_type: type})
       when is_binary(type) and type not in ["", "spec"],
       do: "chat"

  defp entry_audience(_), do: "coding"

  @doc false
  def apply_evaluation(entry, evaluation) do
    recommendation =
      evaluation["recommendation"] || evaluation[:recommendation] || "human_review"

    quality_score = evaluation["quality_score"] || evaluation[:quality_score]
    reasoning = evaluation["reasoning"] || evaluation[:reasoning] || "LLM audit completed"
    audited_at = DateTime.utc_now() |> DateTime.to_iso8601()

    suggested = evaluation["suggested_title"] || evaluation[:suggested_title]

    entry =
      if is_binary(suggested) and String.trim(suggested) != "" and
           String.trim(suggested) != entry.title do
        %{entry | title: String.trim(suggested)}
      else
        entry
      end

    entry = %{
      entry
      | audit_verdict: recommendation,
        audited_at: audited_at,
        audit_reasoning: reasoning,
        quality_score: quality_score
    }

    entry =
      case recommendation do
        "approve" ->
          %{entry | status: "approved", approved_by: "llm"}

        "reject" ->
          %{entry | status: "rejected"}

        _ ->
          # human_review or unknown — stay proposed, parked via audit_verdict
          entry
      end

    case Loader.save(entry) do
      :ok ->
        Logger.info(
          "[Acs.Specs.Auditor] #{entry.app}/#{entry.id} → #{recommendation} (status=#{entry.status})"
        )

      other ->
        Logger.error(
          "[Acs.Specs.Auditor] Failed to persist audit for #{entry.app}/#{entry.id}: #{inspect(other)}"
        )
    end

    %{
      org: nil,
      app: entry.app,
      id: entry.id,
      audit_verdict: recommendation,
      status: entry.status,
      audited_at: audited_at,
      audit_reasoning: reasoning
    }
  end
end

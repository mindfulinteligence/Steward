defmodule Acs.MCP.Tools.CloseWorkTest do
  use Acs.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Acs.Acs.TaskCompletionFeedback
  alias Acs.Acs.Task
  alias Acs.MCP.Tools

  setup do
    tmp_specs =
      Path.expand("../../tmp/close_work_#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(tmp_specs)
    orig_env = System.get_env("SPECS_PATH")
    System.put_env("SPECS_PATH", tmp_specs)

    on_exit(fn ->
      if orig_env,
        do: System.put_env("SPECS_PATH", orig_env),
        else: System.delete_env("SPECS_PATH")

      File.rm_rf!(tmp_specs)
    end)

    :ok
  end

  defp auth_args(extra) do
    Map.merge(
      %{
        "_auth_role" => "admin",
        "_auth_agent_id" => "test_runner",
        "agent_id" => "test_runner"
      },
      extra
    )
  end

  defp create_claimed_task(title, agent) do
    {:ok, task} = Acs.create_task(%{"title" => title}, agent)
    {:ok, claimed, _guidance} = Acs.claim_task(task.slug, agent)
    claimed
  end

  test "close_work saves spec, releases task, and submits feedback in one call" do
    task =
      create_claimed_task(
        "Close Work Full Flow #{System.unique_integer([:positive])}",
        "test_runner"
      )

    assert {:ok, result} =
             Tools.call_tool(
               "close_work",
               auth_args(%{
                 "task_id" => task.slug,
                 "app" => "test_app",
                 "path" => "test/module",
                 "title" => "Close Work Test Module",
                 "purpose" => "Handles the module responsibilities for close-out workflow",
                 "invariants" => ["Must always release task lock"],
                 "workflows" => ["Save spec then release"],
                 "failure_modes" => ["Release failure blocks feedback"],
                 "learned_for_agents" => "Close work learns to save specs."
               })
             )

    assert result.status == "done"
    assert result.task_id == task.slug

    assert %{saved: true} = result.spec
    assert %{submitted: true} = result.feedback

    done_task =
      Repo.one(from t in Task, where: t.slug == ^task.slug)

    assert done_task.status == "done"
    assert is_nil(done_task.locked_by_agent)

    assert Repo.one(
             from f in TaskCompletionFeedback,
               where: f.task_id == ^done_task.id and f.agent_id == "test_runner"
           )

    assert {:ok, _spec} =
             Acs.Specs.Tools.call_tool("specs_get", %{
               "app" => "test_app",
               "path" => "test/module"
             })
  end

  test "close_work skips spec save when app/path omitted but still releases and submits feedback" do
    task =
      create_claimed_task(
        "Close Work No Spec #{System.unique_integer([:positive])}",
        "test_runner"
      )

    assert {:ok, result} =
             Tools.call_tool(
               "close_work",
               auth_args(%{
                 "task_id" => task.slug,
                 "learned_for_agents" => "Feedback only close."
               })
             )

    assert result.status == "done"
    assert %{saved: false} = result.spec

    assert %{submitted: true} = result.feedback

    done_task =
      Repo.one(from t in Task, where: t.slug == ^task.slug)

    assert done_task.status == "done"
  end

  test "close_work on a task locked by another agent returns not_owner and submits no feedback" do
    task =
      create_claimed_task(
        "Close Work Not Owner #{System.unique_integer([:positive])}",
        "other_agent"
      )

    assert {:ok, result} =
             Tools.call_tool(
               "close_work",
               auth_args(%{
                 "task_id" => task.slug,
                 "learned_for_agents" => "Should not be saved."
               })
             )

    assert result.status == "not_owner"

    assert is_nil(
             Repo.one(
               from f in TaskCompletionFeedback,
                 where: f.agent_id == "test_runner" and f.task_id == ^task.id
             )
           )

    still_locked =
      Repo.one(from t in Task, where: t.slug == ^task.slug)

    assert still_locked.status == "in_progress"
    assert still_locked.locked_by_agent == "other_agent"
  end
end

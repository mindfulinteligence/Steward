defmodule Acs.TaskLifecycleTest do
  use Acs.DataCase, async: false

  test "a claimed create is atomic and an expired creator claim can still release" do
    agent = "agent-#{System.unique_integer([:positive])}"

    assert {:ok, task} =
             Acs.create_task(
               %{
                 "title" => "atomic-claim-#{System.unique_integer([:positive])}",
                 "status" => "in_progress"
               },
               agent
             )

    assert task.locked_by_agent == agent
    assert task.auto_release_at

    task
    |> Acs.Acs.Task.changeset(%{
      "locked_by_agent" => nil,
      "locked_at" => nil,
      "auto_release_at" => nil,
      "status" => "todo"
    })
    |> Acs.Repo.update!()

    assert {:ok, released} = Acs.release_task(task.id, agent)
    assert released.status == "done"
  end

  test "agent activity renews the active task lease" do
    agent = "agent-#{System.unique_integer([:positive])}"

    assert {:ok, task} =
             Acs.create_task(
               %{
                 "title" => "renew-lease-#{System.unique_integer([:positive])}",
                 "status" => "in_progress"
               },
               agent
             )

    old_expiry = DateTime.add(DateTime.utc_now(), -1, :minute)
    task |> Acs.Acs.Task.changeset(%{"auto_release_at" => old_expiry}) |> Acs.Repo.update!()

    assert :ok = Acs.touch_task_lease(agent)
    assert DateTime.compare(Acs.get_task(task.id).auto_release_at, DateTime.utc_now()) == :gt
  end
end

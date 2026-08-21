defmodule Acs.Acs.CacheStaleSweepTest do
  use Acs.DataCase, async: false

  alias Acs.Acs.Cache
  alias Acs.Acs.AgentStatus

  test "empty stale sweep does not query the database" do
    handler = "cache-empty-sweep-#{System.unique_integer()}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:steward_acs, :repo, :query],
      fn _, _, _, _ ->
        send(test_pid, :repo_query)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    send(Cache, :sweep_stale_agents)
    :sys.get_state(Cache)

    refute_receive :repo_query
  end

  test "stale sweeper removes agents from non-default orgs" do
    org = "safetyconnect"
    agent_id = "email|ghost-agent-test"

    stale_at = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    :ets.insert(
      :acs_agent_status,
      {{org, agent_id},
       %{
         agent_id: agent_id,
         org: org,
         purpose: "active",
         current_task_id: nil,
         updated_at: stale_at
       }}
    )

    %AgentStatus{}
    |> AgentStatus.changeset(%{agent_id: agent_id, org: org, purpose: "active"})
    |> Repo.insert!()

    assert Cache.get_all_agent_statuses(org) != []
    assert Repo.get_by(AgentStatus, agent_id: agent_id, org: org)

    send(Cache, :sweep_stale_agents)
    :sys.get_state(Cache)

    assert Cache.get_all_agent_statuses(org) == []
    assert Repo.get_by(AgentStatus, agent_id: agent_id, org: org) == nil
  end
end

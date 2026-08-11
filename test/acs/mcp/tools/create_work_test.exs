defmodule Acs.MCP.Tools.CreateWorkTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools

  setup do
    org = "create-work-#{System.unique_integer([:positive])}"
    Acs.Org.put_request_org(org)
    %{org: org}
  end

  defp coding_auth(org, agent) do
    %{
      "agent_id" => agent,
      "_auth_agent_id" => agent,
      "_auth_org_id" => org,
      "_auth_role" => "collaborator",
      "_auth_audience" => "coding"
    }
  end

  test "long description persists verbatim through create_work and list_tasks", %{org: org} do
    long_description =
      String.duplicate(
        "This description is deliberately much longer than two hundred and fifty five characters ",
        5
      )

    assert String.length(long_description) > 255

    assert {:ok, %{task_id: task_id}} =
             Tools.call_tool(
               "create_work",
               Map.merge(coding_auth(org, "nahar"), %{
                 "title" => "Long description task",
                 "description" => long_description,
                 "claim" => false
               })
             )

    assert {:ok, %{tasks: tasks}} =
             Tools.call_tool(
               "list_tasks",
               Map.merge(coding_auth(org, "nahar"), %{"status_filter" => "all"})
             )

    task = Enum.find(tasks, &(&1[:slug] == task_id))
    assert task[:description] == long_description
  end

  test "short description persists", %{org: org} do
    assert {:ok, %{task_id: task_id}} =
             Tools.call_tool(
               "create_work",
               Map.merge(coding_auth(org, "nahar"), %{
                 "title" => "Short description task",
                 "description" => "brief",
                 "claim" => false
               })
             )

    task = Acs.get_task(task_id)
    assert task.description == "brief"
  end
end

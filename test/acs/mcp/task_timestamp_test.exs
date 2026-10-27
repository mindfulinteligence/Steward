defmodule Acs.MCP.TaskTimestampTest do
  use ExUnit.Case, async: true
  alias Acs.MCP.Tools.CoreHandlers

  test "task_timestamp renders ISO-8601 and tolerates nil" do
    assert CoreHandlers.task_timestamp(nil) == nil
    assert CoreHandlers.task_timestamp(~U[2026-10-28 01:02:03Z]) == "2026-10-28T01:02:03Z"
    assert CoreHandlers.task_timestamp(~N[2026-10-28 01:02:03]) == "2026-10-28T01:02:03Z"
  end
end

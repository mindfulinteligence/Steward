defmodule Acs.MCP.HealthCache do
  @moduledoc false

  alias Acs.Observability.CacheOps

  @table :tools_health_cache
  @ttl_seconds 30

  def setup do
    :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    :ok
  end

  def get_all do
    cutoff = cutoff()

    result =
      :ets.foldl(
        fn
          {app, status, ts}, acc when ts > cutoff -> Map.put(acc, app, status)
          _, acc -> acc
        end,
        %{},
        @table
      )

    CacheOps.log(
      cache_name: @table,
      result: if(map_size(result) > 0, do: "hit", else: "miss"),
      count: map_size(result)
    )

    result
  end

  def put_all(results) when is_map(results) do
    now = current_time()
    entries = Enum.map(results, fn {app, status} -> {app, status, now} end)
    :ets.insert(@table, entries)
  end

  defp cutoff, do: current_time() - @ttl_seconds
  defp current_time, do: System.system_time(:second)
end

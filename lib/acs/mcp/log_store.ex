defmodule Acs.MCP.LogStore do
  @moduledoc """
  In-memory log storage using ETS for runtime log capture.
  Provides log retrieval with filtering capabilities for the MCP get_logs tool.

  ## Design

  - Uses negative monotonic IDs for free reverse-chronological ordering
    in the ETS ordered_set (most negative = most recent = appears first
    in forward iteration)
  - Integer-coded log levels (`level_num`) enable match spec filtering
    at the ETS level, avoiding full-table scans
  - `timestamp_epoch` enables TTL-based expiry via match spec
  - Dual retention: 5-minute TTL + 5K hard cap
  """

  use GenServer
  require Logger

  @table_name :mcp_log_store
  @default_limit 100
  @max_logs 5_000
  @max_log_age_seconds 300

  @doc """
  Starts the LogStore GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initializes the ETS table for log storage.
  """
  @impl true
  def init(_opts) do
    if :ets.info(@table_name, :name) != :undefined do
      :ets.delete(@table_name)
    end

    # Create public ETS table for concurrent reads
    :ets.new(@table_name, [
      :ordered_set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Send a message to ourselves to attach the backend after init completes
    # This prevents race conditions where the backend tries to log before
    # the ETS table is fully created
    send(self(), :attach_log_backend)

    {:ok, %{count: 0}}
  end

  @impl true
  def handle_info(:attach_log_backend, state) do
    Logger.add_backend(Acs.MCP.LogBackend)
    {:noreply, state}
  end

  @doc """
  Stores a log entry in the ETS table and persists it to the database.

  Called by the LogBackend. The ETS write is synchronous for fast recent
  queries. The DB write is fire-and-forget (async) so it never blocks
  the ETS path.

  Returns `:ok` or `{:error, :no_table}` if the ETS table doesn't exist.
  DB write errors are silently caught — they never propagate to the caller.
  """
  def store_log(level, service, component, message, metadata \\ %{}) do
    if not table_exists?() do
      {:error, :no_table}
    else
      org = Map.get(metadata, :org) || Map.get(metadata, "org") || Acs.Org.current()
      result = do_store_log(level, service, component, message, metadata, org)

      # DB persistence (fire-and-forget, don't block ETS write). Paused while
      # idle so background log lines don't keep the Neon compute awake — the
      # ETS path and the Axiom exporter still capture everything.
      if Application.get_env(:steward_acs, :persist_logs_to_db, true) and
           not Acs.IdleTracker.idle?() do
        persist_to_db(level, service, component, message, metadata, org)
      end

      result
    end
  end

  # Persist log to the database asynchronously.
  # Errors are caught silently — the ETS write path must never be disrupted
  # by a DB failure.
  defp persist_to_db(level, service, component, message, metadata, org) do
    # Rescue inside the Task: EncodeError used to crash here, Logger reported it,
    # LogBackend re-entered store_log, and the pool wedged (health → 503).
    Task.start(fn ->
      try do
        case Acs.Log.LogRepo.insert_raw(
               level,
               service,
               component,
               message,
               metadata,
               org: org
             ) do
          {:error, _reason} -> :ok
          _ -> :ok
        end
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Use negative monotonic IDs so that ETS ordered_set forward iteration
  # gives newest-first order (most negative = most recent = first key).
  defp do_store_log(level, service, component, message, metadata, org) do
    id = -System.unique_integer([:positive, :monotonic])

    entry = %{
      id: id,
      timestamp: DateTime.utc_now(),
      timestamp_epoch: DateTime.utc_now() |> DateTime.to_unix(),
      level: level,
      level_num: level_to_int(level),
      service: service,
      component: component,
      message: message,
      metadata: metadata,
      workflow_id: metadata[:workflow_id],
      execution_id: metadata[:execution_id],
      org: org
    }

    :ets.insert(@table_name, {entry.id, entry})
    trim_old_logs()

    :ok
  end

  defp level_to_int(:debug), do: 0
  defp level_to_int(:info), do: 1
  defp level_to_int(:warning), do: 2
  defp level_to_int(:error), do: 3
  defp level_to_int(_), do: 1

  defp table_exists? do
    :ets.info(@table_name, :name) != :undefined
  rescue
    e ->
      Logger.warning("[LogStore] ETS table_exists? error: #{inspect(e)}")
      false
  end

  @doc """
  Retrieves logs with optional filtering.

  ## Options

    * `:level` - Minimum log level (`:debug`, `:info`, `:warning`, `:error`)
    * `:component` - Exact component name filter
    * `:module` - Partial (substring) match on the module part of the component
    * `:search` - Substring match in message text (case-insensitive)
    * `:action` - Exact match on structured action field
    * `:tags` - Filter by tags (AND logic, supports `prefix:*` wildcards)
    * `:workflow_id` - Filter by workflow ID
    * `:execution_id` - Filter by execution ID
    * `:since` - Start time (ISO8601 string or DateTime)
    * `:until` - End time (ISO8601 string or DateTime)
    * `:limit` - Max entries to return (default: 100)
    * `:offset` - Number of matching entries to skip (default: 0)
    * `:compact` - Return compact format (fewer tokens)
    * `:before_id` - Cursor: entries before (older than) this ID ("load more")
    * `:after_id` - Cursor: entries after (newer than) this ID ("refresh")
    * `:context_size` - Context lines for errors_with_context mode (default: 5)

  ## Mode

    * `"list"` (default) - Normal paginated results including `total` table size
    * `"summary"` - Returns aggregated `%{summary: %{total, by_level, top_components, recent_errors}}`
    * `"errors_with_context"` - Returns error entries with context entries injected

  Returns `%{logs: list(map), count: integer, filtered_total: integer, total: integer}` for list mode.
  Returns `%{summary: %{total: integer, by_level: map, top_components: list, recent_errors: list}}` for summary mode.
  """
  def get_logs(opts \\ [], mode \\ "list") do
    org = Keyword.get(opts, :org, Acs.Org.current())
    level_filter = parse_level(opts[:level])
    component_filter = opts[:component]
    module_filter = opts[:module]
    search_filter = opts[:search]
    tags_filter = opts[:tags]
    action_filter = opts[:action]
    since = parse_datetime(opts[:since])
    until_time = parse_datetime(opts[:until])
    workflow_id = opts[:workflow_id]
    execution_id = opts[:execution_id]
    service_filter = opts[:service]
    limit = opts[:limit] || @default_limit
    offset = opts[:offset] || 0
    compact_mode = opts[:compact] || false
    context_size = opts[:context_size] || 5
    before_id = opts[:before_id]
    after_id = opts[:after_id]

    # Cursor-based pagination: if before_id or after_id is given, use those
    # to directly navigate the ETS ordered_set instead of scanning + slicing
    {entries, total_matching} =
      if before_id || after_id do
        # Cursor mode: navigate ETS directly from the cursor
        # With negative IDs, more negative = newer
        # before_id = get entries OLDER than this ID ("load more")
        # after_id = get entries NEWER than this ID ("refresh")
        cursor_entries =
          if before_id do
            # Walk forward (to larger/less-negative IDs = older entries)
            get_context_before_raw(before_id, limit)
          else
            # Walk backward (to smaller/more-negative IDs = newer entries)
            get_context_after_raw(after_id, limit)
          end

        # Apply filters to the cursor results
        filtered =
          cursor_entries
          |> Enum.filter(&(&1.org == org))
          |> Enum.filter(&matches_level?(&1.level_num, level_filter))
          |> Enum.filter(&matches_component?(&1.component, component_filter))
          |> Enum.filter(&matches_module?(&1.component, module_filter))
          |> Enum.filter(&matches_search?(&1.message, search_filter))
          |> Enum.filter(&matches_tags?(&1.metadata, tags_filter))
          |> Enum.filter(&matches_action?(&1.metadata[:action], action_filter))
          |> Enum.filter(&matches_time?(&1.timestamp, since, until_time))
          |> Enum.filter(&matches_field?(&1.workflow_id, workflow_id))
          |> Enum.filter(&matches_field?(&1.execution_id, execution_id))
          |> Enum.filter(&matches_service?(&1.service, service_filter))

        {filtered, length(filtered)}
      else
        # Non-cursor mode: standard match-spec + slice
        match_spec = build_match_spec(level_filter, component_filter, service_filter)

        # Fetch a generous buffer — the continuation is discarded since our
        # tables are small (≤5000 entries) and the factor-2 buffer covers
        # most real-world queries
        fetch_size = (limit + offset) * 2

        selected =
          case :ets.select(@table_name, match_spec, fetch_size) do
            :"$end_of_table" -> []
            {results, _cont} -> results
          end

        # Post-filter in Elixir for complex conditions that cannot
        # be expressed concisely in match specs
        filtered =
          selected
          |> Enum.map(fn {_id, entry} -> entry end)
          |> Enum.filter(&(&1.org == org))
          |> Enum.filter(&matches_module?(&1.component, module_filter))
          |> Enum.filter(&matches_search?(&1.message, search_filter))
          |> Enum.filter(&matches_tags?(&1.metadata, tags_filter))
          |> Enum.filter(&matches_action?(&1.metadata[:action], action_filter))
          |> Enum.filter(&matches_time?(&1.timestamp, since, until_time))
          |> Enum.filter(&matches_field?(&1.workflow_id, workflow_id))
          |> Enum.filter(&matches_field?(&1.execution_id, execution_id))
          |> Enum.filter(&matches_service?(&1.service, service_filter))

        sliced = Enum.slice(filtered, offset, limit)
        {sliced, length(filtered)}
      end

    case mode do
      "summary" ->
        build_summary(entries)

      _ ->
        formatted =
          case mode do
            "errors_with_context" ->
              format_errors_with_context(entries, context_size, org)

            _ ->
              Enum.map(entries, &format_entry(&1, compact_mode))
          end

        result = %{
          logs: formatted,
          count: length(formatted),
          filtered_total: total_matching,
          total: tenant_log_count(org)
        }

        # Add helpful note when no results match
        if result.count == 0 do
          level_hint =
            case level_filter do
              nil ->
                "No level filter was applied."

              :error ->
                "You filtered by level \"error\" but no error logs were found."

              :warning ->
                "You filtered by level \"warning\" but no warning logs were found."

              :info ->
                "You filtered by level \"info\" but no info logs were found."

              :debug ->
                "You filtered by level \"debug\" but no debug logs were found."

              _unknown ->
                "You filtered by level \"#{opts[:level]}\" (this level is not recognized, defaulted to :info). Try without level filter or use level: \"debug\" to see all logs."
            end

          Map.put(
            result,
            :note,
            "No logs matched your filters. #{level_hint} Default limit is #{@default_limit}. Try adjusting your filters or increasing limit."
          )
        else
          result
        end
    end
  end

  @doc """
  Clears all stored logs.
  """
  def clear_logs do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Gets recent logs for a specific execution.
  """
  def get_execution_logs(execution_id, limit \\ 50) do
    get_logs(execution_id: execution_id, limit: limit)
  end

  @doc """
  Gets recent logs for a specific workflow.
  """
  def get_workflow_logs(workflow_id, limit \\ 50) do
    get_logs(workflow_id: workflow_id, limit: limit)
  end

  @doc """
  Retrieves N log entries that were logged before the entry with the given ID.
  Uses the ETS ordered_set key ordering to navigate backwards from the entry.

  Returns `%{logs: list, count: integer}`.
  """
  def get_context_before(entry_id, limit \\ 30, org \\ Acs.Org.current())

  def get_context_before(entry_id, limit, org)
      when is_integer(entry_id) and limit > 0 and is_binary(org) do
    entries = collect_previous_entries(@table_name, entry_id, limit, [], org)

    formatted = Enum.map(entries, &format_entry/1)

    %{logs: formatted, count: length(formatted)}
  end

  # --- Private Functions ---

  # -- Match spec builders --

  # No level/component/service filter — return all entries (newest-first via negative IDs)
  defp build_match_spec(nil, nil, nil) do
    [{{:"$1", :"$2"}, [], [:"$_"]}]
  end

  # Level filter only — level_num >= threshold
  defp build_match_spec(level_filter, nil, nil) do
    [
      {{:"$1", :"$2"}, [{:>=, {:map_get, :level_num, :"$2"}, level_to_int(level_filter)}],
       [:"$_"]}
    ]
  end

  # Component filter only — exact match
  defp build_match_spec(nil, component_filter, nil) do
    [
      {{:"$1", :"$2"}, [{:==, {:map_get, :component, :"$2"}, component_filter}], [:"$_"]}
    ]
  end

  # Service filter only — exact match
  defp build_match_spec(nil, nil, service_filter) do
    [
      {{:"$1", :"$2"}, [{:==, {:map_get, :service, :"$2"}, service_filter}], [:"$_"]}
    ]
  end

  # Level and component filter
  defp build_match_spec(level_filter, component_filter, nil) do
    [
      {{:"$1", :"$2"},
       [
         {:andalso, {:>=, {:map_get, :level_num, :"$2"}, level_to_int(level_filter)},
          {:==, {:map_get, :component, :"$2"}, component_filter}}
       ], [:"$_"]}
    ]
  end

  # Level and service filter
  defp build_match_spec(level_filter, nil, service_filter) do
    [
      {{:"$1", :"$2"},
       [
         {:andalso, {:>=, {:map_get, :level_num, :"$2"}, level_to_int(level_filter)},
          {:==, {:map_get, :service, :"$2"}, service_filter}}
       ], [:"$_"]}
    ]
  end

  # Component and service filter
  defp build_match_spec(nil, component_filter, service_filter) do
    [
      {{:"$1", :"$2"},
       [
         {:andalso, {:==, {:map_get, :component, :"$2"}, component_filter},
          {:==, {:map_get, :service, :"$2"}, service_filter}}
       ], [:"$_"]}
    ]
  end

  # Level, component, and service filter
  defp build_match_spec(level_filter, component_filter, service_filter) do
    [
      {{:"$1", :"$2"},
       [
         {:andalso, {:>=, {:map_get, :level_num, :"$2"}, level_to_int(level_filter)},
          {:andalso, {:==, {:map_get, :component, :"$2"}, component_filter},
           {:==, {:map_get, :service, :"$2"}, service_filter}}}
       ], [:"$_"]}
    ]
  end

  # -- ETS collection helpers --

  defp collect_previous_entries(_table, _key, 0, acc, _org), do: acc
  defp collect_previous_entries(_table, :"$end_of_table", _limit, acc, _org), do: acc

  defp collect_previous_entries(table, key, limit, acc, org) do
    # With negative monotonic IDs, more negative = more recent, so the
    # chronologically *previous* entries have larger (less negative) IDs.
    # Use :ets.next to walk forward to larger keys.
    case :ets.next(table, key) do
      :"$end_of_table" ->
        acc

      next_key ->
        case :ets.lookup(table, next_key) do
          [{^next_key, %{org: ^org} = entry}] ->
            collect_previous_entries(table, next_key, limit - 1, [entry | acc], org)

          [{^next_key, _entry}] ->
            collect_previous_entries(table, next_key, limit, acc, org)

          _ ->
            acc
        end
    end
  end

  # -- Cursor-based pagination helpers (for before_id/after_id) --

  defp get_context_before_raw(entry_id, limit) do
    # Walk forward (to larger/less-negative IDs) = chronologically older
    collect_forward(@table_name, entry_id, limit, [])
  end

  defp get_context_after_raw(entry_id, limit) do
    # Walk backward (to smaller/more-negative IDs) = chronologically newer
    collect_backward(@table_name, entry_id, limit, [])
  end

  defp collect_forward(_table, _key, 0, acc), do: acc
  defp collect_forward(_table, :"$end_of_table", _limit, acc), do: acc

  defp collect_forward(table, key, limit, acc) do
    case :ets.next(table, key) do
      :"$end_of_table" ->
        acc

      next_key ->
        case :ets.lookup(table, next_key) do
          [{^next_key, entry}] ->
            collect_forward(table, next_key, limit - 1, [entry | acc])

          _ ->
            acc
        end
    end
  end

  defp collect_backward(_table, _key, 0, acc), do: acc
  defp collect_backward(_table, :"$end_of_table", _limit, acc), do: acc

  defp collect_backward(table, key, limit, acc) do
    case :ets.prev(table, key) do
      :"$end_of_table" ->
        acc

      prev_key ->
        case :ets.lookup(table, prev_key) do
          [{^prev_key, entry}] ->
            collect_backward(table, prev_key, limit - 1, [entry | acc])

          _ ->
            acc
        end
    end
  end

  # -- Retention --

  defp trim_old_logs do
    # 1. Remove by TTL (timestamp_epoch based)
    cutoff = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(@max_log_age_seconds)

    ttl_spec = [
      {{:"$1", :"$2"}, [{:<, {:map_get, :timestamp_epoch, :"$2"}, cutoff}], [:"$_"]}
    ]

    case :ets.select(@table_name, ttl_spec, 100) do
      :"$end_of_table" ->
        :ok

      {old_entries, :"$end_of_table"} ->
        Enum.each(old_entries, fn {id, _} -> :ets.delete(@table_name, id) end)

      {old_entries, _cont} ->
        Enum.each(old_entries, fn {id, _} -> :ets.delete(@table_name, id) end)
    end

    # 2. Enforce hard cap
    count = :ets.info(@table_name, :size)

    if count > @max_logs do
      to_delete = count - @max_logs
      delete_oldest(to_delete)
    end
  end

  defp delete_oldest(0), do: :ok

  defp delete_oldest(count) do
    # With negative IDs, the largest key (= last in ordered_set) is the oldest.
    # :ets.last gives us the oldest entry to delete first.
    case :ets.last(@table_name) do
      :"$end_of_table" ->
        :ok

      last_key ->
        :ets.delete(@table_name, last_key)
        delete_oldest(count - 1)
    end
  end

  # -- Formatting --

  defp format_entry(entry, compact \\ false)

  defp format_entry(entry, false) do
    %{
      id: entry.id,
      ts: DateTime.to_iso8601(entry.timestamp),
      lvl: to_string(entry.level),
      svc: entry.service,
      cmp: entry.component,
      msg: entry.message
    }
    |> add_if(entry.workflow_id, :wf)
    |> add_if(entry.execution_id, :exec)
    |> then(fn m ->
      if entry.metadata == %{} do
        m
      else
        meta = entry.metadata

        m
        |> add_if(meta[:error_type], :err)
        |> add_if(meta[:call_type], :ct)
        |> add_if(meta[:agent_name], :ag)
        |> add_if(meta[:model], :mdl)
        |> add_if(meta[:provider], :prv)
        |> add_if(meta[:tokens_in], :tkn_in)
        |> add_if(meta[:tokens_out], :tkn_out)
        |> add_if(meta[:latency_ms], :lat)
        |> add_if(meta[:llm_event], :llm_ev)
        |> add_if(meta[:status], :st)
        |> add_if(meta[:action], :act)
        |> add_if(meta[:params], :params)
        |> add_if(meta[:tags], :tags)
        |> add_if(meta[:system_tags], :s_tags)
      end
    end)
  end

  defp format_entry(entry, true) do
    # Compact mode: abbreviated keys, truncated timestamps, compact components
    %{
      t: format_timestamp_compact(entry.timestamp),
      l: String.first(to_string(entry.level)),
      svc: entry.service,
      c: compact_component(entry.component),
      m: entry.message
    }
    |> add_if(entry.workflow_id, :w)
    |> add_if(entry.execution_id, :e)
    |> then(fn m ->
      if entry.metadata == %{} do
        m
      else
        meta = entry.metadata

        m
        |> add_if(meta[:error_type], :x)
        |> add_if(meta[:action], :a)
        |> add_if(meta[:latency_ms], :d)
        |> add_if(meta[:tokens_in], :i)
        |> add_if(meta[:tokens_out], :o)
        |> add_if(meta[:model], :M)
        |> add_if(meta[:provider], :p)
        |> add_if(meta[:status], :s)
      end
    end)
  end

  defp format_timestamp_compact(%DateTime{} = dt) do
    "#{pad(dt.hour)}:#{pad(dt.minute)}:#{pad(dt.second)}"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: Integer.to_string(n)

  defp compact_component(component) do
    component
    |> String.split("::")
    |> Enum.map_join("::", &String.slice(&1, 0, 1))
  end

  # -- Summary mode aggregation --

  defp build_summary(entries) do
    total = length(entries)

    by_level =
      entries
      |> Enum.group_by(& &1.level)
      |> Map.new(fn {level, list} -> {level, length(list)} end)

    top_components =
      entries
      |> Enum.group_by(& &1.component)
      |> Enum.map(fn {comp, list} -> %{cmp: comp, count: length(list)} end)
      |> Enum.sort_by(& &1.count, :desc)
      |> Enum.take(10)

    recent_errors =
      entries
      |> Enum.filter(&(&1.level == :error))
      |> Enum.take(5)
      |> Enum.map(fn e ->
        %{
          t: format_timestamp_compact(e.timestamp),
          c: compact_component(e.component),
          m: String.slice(e.message, 0, 120)
        }
      end)

    %{
      summary: %{
        total: total,
        by_level: by_level,
        top_components: top_components,
        recent_errors: recent_errors
      }
    }
  end

  # -- Errors-with-context formatting --

  defp format_errors_with_context(entries, context_size, org) do
    errors = Enum.filter(entries, &(&1.level == :error)) |> Enum.take(10)

    if errors == [] do
      []
    else
      Enum.flat_map(errors, fn error ->
        context = get_context_before(error.id, context_size, org).logs
        context ++ [format_entry(error, true)]
      end)
    end
  end

  defp tenant_log_count(org) do
    :ets.foldl(
      fn
        {_id, %{org: ^org}}, count -> count + 1
        _entry, count -> count
      end,
      0,
      @table_name
    )
  end

  # -- Nil-stripping helper --

  defp add_if(map, nil, _key), do: map
  defp add_if(map, value, _key) when is_list(value) and value == [], do: map
  defp add_if(map, value, key), do: Map.put(map, key, value)

  # -- Post-filter helpers (applied in Elixir) --

  defp matches_module?(_component, nil), do: true

  defp matches_module?(component, filter) when is_binary(filter) do
    String.contains?(String.downcase(component), String.downcase(filter))
  end

  defp matches_search?(_message, nil), do: true

  defp matches_search?(message, filter) when is_binary(filter) do
    String.contains?(String.downcase(message), String.downcase(filter))
  end

  defp matches_tags?(_metadata, nil), do: true

  defp matches_tags?(metadata, filters) when is_list(filters) do
    entry_sys = Map.get(metadata, :system_tags, []) |> List.wrap()
    entry_usr = Map.get(metadata, :tags, []) |> List.wrap()
    entry_all = entry_sys ++ entry_usr

    Enum.all?(filters, fn filter ->
      normalized = String.downcase(filter)

      if String.contains?(normalized, ":*") do
        prefix = String.replace_suffix(normalized, ":*", "")
        Enum.any?(entry_all, fn t -> String.starts_with?(t, prefix <> ":") end)
      else
        normalized in entry_all
      end
    end)
  end

  defp matches_action?(nil, nil), do: true
  defp matches_action?(_stored, nil), do: true
  defp matches_action?(nil, _filter), do: false
  defp matches_action?(stored, filter), do: stored == filter

  defp matches_time?(_timestamp, nil, nil), do: true

  defp matches_time?(timestamp, since, nil) do
    DateTime.compare(timestamp, since) in [:gt, :eq]
  end

  defp matches_time?(timestamp, nil, until_time) do
    DateTime.compare(timestamp, until_time) in [:lt, :eq]
  end

  defp matches_time?(timestamp, since, until_time) do
    DateTime.compare(timestamp, since) in [:gt, :eq] and
      DateTime.compare(timestamp, until_time) in [:lt, :eq]
  end

  defp matches_field?(_value, nil), do: true
  defp matches_field?(value, filter), do: value == filter

  defp matches_level?(_level_num, nil), do: true

  defp matches_level?(level_num, filter) when is_atom(filter) do
    level_num >= level_to_int(filter)
  end

  defp matches_component?(_component, nil), do: true

  defp matches_component?(component, filter) when is_binary(filter) do
    component == filter
  end

  defp matches_service?(_service, nil), do: true

  defp matches_service?(service, filter) when is_binary(filter) do
    service == filter
  end

  # -- Parsing --

  defp parse_level(nil), do: nil
  defp parse_level("debug"), do: :debug
  defp parse_level("info"), do: :info
  defp parse_level("warning"), do: :warning
  defp parse_level("warn"), do: :warning
  defp parse_level("error"), do: :error
  defp parse_level(level) when is_atom(level), do: level
  defp parse_level(_unknown), do: :info

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end

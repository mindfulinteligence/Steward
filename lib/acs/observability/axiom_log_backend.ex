defmodule Acs.Observability.AxiomLogBackend do
  @moduledoc false

  @behaviour :gen_event

  alias Acs.Observability.AxiomLogExporter

  @ignored_modules [
    __MODULE__,
    AxiomLogExporter,
    Acs.MCP.LogStore,
    Acs.MCP.LogBackend,
    Acs.MCP.LogStoreServer,
    Acs.MCP.HTTPServer,
    Acs.MCP.Protocol
  ]

  # Keep the remote schema useful and bounded without accidentally exporting
  # arbitrary Logger metadata such as connections, credentials, or structs.
  @metadata_fields [
    :agent_id,
    :task_id,
    :file_path,
    :locked_by,
    :workflow_id,
    :execution_id,
    :node_id,
    :call_type,
    :agent_name,
    :model,
    :provider,
    :base_url,
    :tokens_in,
    :tokens_out,
    :tokens_total,
    :latency_ms,
    :llm_event,
    :call_type,
    :subject_id,
    :audience,
    :prompt_chars,
    :recommendation,
    :quality_score,
    :status,
    :error_type,
    :action,
    :params,
    :org,
    :tags,
    :role,
    :request_id,
    :component,
    :live_view,
    :page,
    :service,
    :count,
    :cache_name,
    :cache_result,
    :cache_type,
    :next_provider,
    :providers,
    :trace_id,
    :span_id,
    :trace_flags
  ]

  @max_string_bytes 16_384
  @max_collection_size 100
  @max_metadata_depth 4
  @sensitive_key ~r/(authorization|password|passwd|secret|token|api.?key|cookie|credential|signature)/i

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call(_, state), do: {:ok, :ok, state}

  @impl true
  def handle_event({_level, group_leader, {Logger, _, _, _}}, state)
      when node(group_leader) != node(),
      do: {:ok, state}

  @impl true
  def handle_event({events, _handler_state}, state) when is_tuple(events) do
    events
    |> Tuple.to_list()
    |> Enum.each(fn
      {level, group_leader, {Logger, message, timestamp, metadata}} ->
        export(level, group_leader, message, timestamp, metadata)

      _ ->
        :ok
    end)

    {:ok, state}
  end

  @impl true
  def handle_event({level, group_leader, {Logger, message, timestamp, metadata}}, state) do
    export(level, group_leader, message, timestamp, metadata)
    {:ok, state}
  end

  @impl true
  def handle_event(_, state), do: {:ok, state}

  @doc false
  def to_event(level, message, timestamp, metadata) do
    metadata = Map.new(metadata)
    module = metadata[:module] || mfa_module(metadata[:mfa])
    level_name = to_string(level)

    fields =
      @metadata_fields
      |> Enum.reduce(%{}, fn key, acc ->
        case Map.fetch(metadata, key) do
          {:ok, nil} -> acc
          {:ok, value} -> Map.put(acc, to_string(key), json_value(value))
          :error -> acc
        end
      end)

    Map.merge(fields, %{
      "_time" => format_timestamp(timestamp),
      "message" => format_message(message),
      "severity" => String.upcase(level_name),
      "level" => level_name,
      "service" => "steward_acs",
      "module" => format_module(module)
    })
  end

  defp export(level, group_leader, message, timestamp, metadata) do
    metadata = Map.new(metadata)
    module = metadata[:module] || mfa_module(metadata[:mfa])

    if local_event?(group_leader) and module not in @ignored_modules and
         metadata[:axiom_exporter_internal] != true do
      AxiomLogExporter.enqueue(to_event(level, message, timestamp, metadata))
    end
  rescue
    _ -> :ok
  end

  defp local_event?(nil), do: true
  defp local_event?(group_leader) when is_pid(group_leader), do: node(group_leader) == node()
  defp local_event?(_), do: true

  defp mfa_module({module, _function, _arity}), do: module
  defp mfa_module(_), do: nil

  defp format_module(nil), do: "Unknown"

  defp format_module(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp format_module(module), do: module |> to_string() |> truncate_string()

  defp format_message(message) when is_binary(message), do: truncate_string(message)

  defp format_message(message) when is_list(message) do
    message
    |> IO.iodata_to_binary()
    |> truncate_string()
  rescue
    _ -> inspect(message, limit: @max_collection_size) |> truncate_string()
  end

  defp format_message(message),
    do: inspect(message, limit: @max_collection_size) |> truncate_string()

  defp format_timestamp({{year, month, day}, {hour, minute, second, millisecond}})
       when is_integer(millisecond) do
    with {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second, {millisecond * 1_000, 3}),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      DateTime.to_iso8601(datetime)
    else
      _ -> now_iso8601()
    end
  end

  defp format_timestamp(system_time) when is_integer(system_time) do
    system_time
    |> DateTime.from_unix(:microsecond)
    |> case do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> now_iso8601()
    end
  end

  defp format_timestamp(_), do: now_iso8601()

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp json_value(value, depth \\ 0)
  defp json_value(value, _depth) when is_nil(value) or is_boolean(value), do: value
  defp json_value(value, _depth) when is_integer(value) or is_float(value), do: value
  defp json_value(value, _depth) when is_binary(value), do: truncate_string(value)
  defp json_value(value, _depth) when is_atom(value), do: Atom.to_string(value)

  defp json_value(_value, depth) when depth >= @max_metadata_depth, do: "[TRUNCATED]"

  defp json_value(value, depth) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.take(@max_collection_size)
      |> Map.new(&json_pair(&1, depth))
    else
      value
      |> Enum.take(@max_collection_size)
      |> Enum.map(&json_value(&1, depth + 1))
    end
  end

  defp json_value(%_{} = _struct, _depth), do: "[STRUCT]"

  defp json_value(value, depth) when is_map(value) do
    value
    |> Enum.take(@max_collection_size)
    |> Map.new(&json_pair(&1, depth))
  end

  defp json_value(_value, _depth), do: "[UNSUPPORTED]"

  defp json_pair({key, value}, depth) do
    key = to_string(key)

    {key,
     if(Regex.match?(@sensitive_key, key), do: "[REDACTED]", else: json_value(value, depth + 1))}
  end

  defp truncate_string(value) do
    value = String.replace_invalid(value)

    if byte_size(value) <= @max_string_bytes do
      value
    else
      value
      |> binary_part(0, @max_string_bytes - byte_size("…"))
      |> valid_utf8_prefix()
      |> Kernel.<>("…")
    end
  end

  defp valid_utf8_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_utf8_prefix(binary_part(value, 0, byte_size(value) - 1))
  end
end

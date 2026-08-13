defmodule Acs.Observability.AgentOps do
  @moduledoc """
  Agent-facing usage telemetry for Steward.

  Emits flat, APL-friendly `agent.tool` / `agent.tools_list` / `agent.feedback`
  events so coding agents (and Axiom dashboards) can analyze Claude/chat vs
  coding usage without parsing free-text logs.

  Learning signals (filter on `signal`):
  - `works` — successful retrieve with hits, or useful guidance feedback
  - `gap_empty` — retrieve returned nothing (knowledge missing or bad scope)
  - `gap_info` — feedback says info was needed
  - `misuse_discovery` — unknown tool name
  - `misuse_write` — write with no prior retrieve in the same chain
  - `surprise_persist` — write after an empty retrieve (unplanned fill / invent)
  - `intake_gate` — save_memory/skill_save blocked for clarification (slows Claude)
  - `intake_bypass` — write used intake_confirmed after a gate
  - `win` — feedback with learned_for_agents (what worked, often unplanned)
  - `pain` — feedback with had_issues / improvements

  Dual-write:
  - Axiom `steward_meta_analytics` (or primary logs dataset) when Axiom is enabled
  - `acs_tool_operations` via MetaHarness when `META_HARNESS_ENABLED=true`
    (intake gates set `error_type` like `intake_needs_input` for Analyzer clusters
    without counting as tool failures)

  Also emits `agent.embedding` (Ollama latency) and `agent.search` (hybrid
  impressions with per-signal scores for weight learning) for dashboards.
  """

  alias Acs.Observability.AxiomLogExporter

  @event_tool "agent.tool"
  @event_tools_list "agent.tools_list"
  @event_feedback "agent.feedback"
  @event_embedding "agent.embedding"
  @event_search "agent.search"

  @retrieve_tools ~w(ask query_memories query_specs skill_get specs_get generate_guidance_packet get_started)
  @write_tools ~w(save_memory documents_propose specs_propose skill_save set_memory_status update_memory specs_approve specs_reject)
  @intake_tools ~w(save_memory skill_save)
  @task_tools ~w(create_work claim_work release_work close_work submit_task_feedback list_tasks lock_file unlock_file get_present_status)

  @doc """
  Log one MCP tool invocation.

  ## Options
  - `:tool_name` (required)
  - `:result` — tool return value (used for status + result_count)
  - `:latency_ms`, `:agent_id`, `:org`, `:audience`, `:role`
  - `:execution_id`, `:task_id`
  - `:scope_path`, `:kind` — knowledge context when present on the call
  - `:discovery` — true when the tool name was unknown
  - `:args` — original tool args (used to detect intake_confirmed bypass)
  - `:client_name`, `:mcp_endpoint`, `:audience_source` — MCP session tags
  """
  def log_tool(opts) when is_list(opts) do
    tool_name = Keyword.fetch!(opts, :tool_name)
    result = Keyword.get(opts, :result)
    discovery? = Keyword.get(opts, :discovery, false)
    args = Keyword.get(opts, :args) || %{}
    routed = effective_tool_name(tool_name, args)

    {status, error_type, error_message} =
      if discovery?, do: {"discovery", nil, nil}, else: result_status(result)

    intake = if discovery?, do: %{}, else: intake_meta(routed, result, args)

    {error_type, error_message} =
      case intake do
        %{outcome: outcome} when outcome in ["needs_input", "needs_scope_choice"] ->
          {"intake_#{outcome}", intake[:notes] || outcome}

        %{outcome: "bypass"} ->
          {"intake_bypass", "intake_confirmed"}

        _ ->
          {error_type, error_message}
      end

    result_count = result_count(routed, result)
    empty_result = is_integer(result_count) and result_count == 0 and status == "success"
    chain_id = chain_id(opts)
    sequence = next_sequence(chain_id)
    family = tool_family(tool_name, args)
    audience = normalize_audience(Keyword.get(opts, :audience))
    chain = note_chain(chain_id, family, empty_result)

    write_without_retrieve = family == "write" and not chain.seen_retrieve
    after_empty_retrieve = family == "write" and chain.last_empty == true

    signal =
      tool_signal(
        discovery?,
        family,
        empty_result,
        result_count,
        write_without_retrieve,
        after_empty_retrieve,
        Map.get(intake, :outcome)
      )

    event = %{
      "_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "message" => @event_tool,
      "event" => @event_tool,
      "severity" => "INFO",
      "level" => "info",
      "service" => "steward_acs",
      "module" => "Acs.Observability.AgentOps",
      "tool_name" => tool_name,
      "routed_tool" => if(routed != tool_name, do: routed),
      "tool_family" => family,
      "status" => status,
      "signal" => signal,
      "latency_ms" => Keyword.get(opts, :latency_ms),
      "agent_id" => Keyword.get(opts, :agent_id),
      "org" => Keyword.get(opts, :org),
      "audience" => audience,
      "audience_source" => audience_source(Keyword.get(opts, :audience_source)),
      "client_name" => truncate(Keyword.get(opts, :client_name), 120),
      "mcp_endpoint" => truncate(Keyword.get(opts, :mcp_endpoint), 200),
      "role" => Keyword.get(opts, :role),
      "execution_id" => Keyword.get(opts, :execution_id),
      "task_id" => Keyword.get(opts, :task_id),
      "scope_path" => truncate(Keyword.get(opts, :scope_path), 200),
      "kind" => Keyword.get(opts, :kind),
      "execution_chain_id" => chain_id,
      "sequence_order" => sequence,
      "result_count" => result_count,
      "empty_result" => empty_result,
      "write_without_retrieve" => write_without_retrieve,
      "after_empty_retrieve" => after_empty_retrieve,
      "tool_discovered" => discovery?,
      "error_type" => error_type,
      "error_message" => error_message && String.slice(to_string(error_message), 0, 500),
      "intake_outcome" => Map.get(intake, :outcome),
      "intake_source" => Map.get(intake, :source),
      "intake_question_id" => Map.get(intake, :question_id),
      "intake_sensitive" => Map.get(intake, :suggested_sensitive),
      "intake_provider" => Map.get(intake, :provider),
      "intake_model" => Map.get(intake, :model)
    }

    enqueue_axiom(event)

    maybe_meta_harness(
      tool_name,
      status,
      opts,
      error_type,
      error_message,
      chain_id,
      sequence,
      discovery?
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Log one MCP `tools/list` inventory (what schemas were advertised).

  ## Options
  - `:tools` — list of MCP tool maps (`%{"name" => ...}`) or name strings
  - `:audience`, `:audience_source`, `:client_name`, `:client_version`
  - `:mcp_endpoint`, `:role`, `:org`, `:agent_id`
  """
  def log_tools_list(opts) when is_list(opts) do
    names = tool_names_from_list(Keyword.get(opts, :tools) || [])
    fields = tools_list_fields(names, opts)

    event =
      Map.merge(
        %{
          "_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "message" => @event_tools_list,
          "event" => @event_tools_list,
          "severity" => "INFO",
          "level" => "info",
          "service" => "steward_acs",
          "module" => "Acs.Observability.AgentOps"
        },
        fields
      )

    enqueue_axiom(event)
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  def tool_names_from_list(tools) when is_list(tools) do
    tools
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> name
      %{name: name} when is_binary(name) -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.sort()
  end

  def tool_names_from_list(_), do: []

  @doc false
  def tools_hash(names) when is_list(names) do
    names
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def tools_list_fields(names, opts) when is_list(names) and is_list(opts) do
    %{
      "audience" => normalize_audience(Keyword.get(opts, :audience)),
      "audience_source" => audience_source(Keyword.get(opts, :audience_source)),
      "client_name" => truncate(Keyword.get(opts, :client_name), 120),
      "client_version" => truncate(Keyword.get(opts, :client_version), 64),
      "mcp_endpoint" => truncate(Keyword.get(opts, :mcp_endpoint), 200),
      "role" => Keyword.get(opts, :role),
      "org" => Keyword.get(opts, :org),
      "agent_id" => Keyword.get(opts, :agent_id),
      "tool_count" => length(names),
      "tool_names" => names,
      "tools_hash" => tools_hash(names)
    }
  end

  @doc "Log structured task feedback for agent/dashboard analysis."
  def log_feedback(opts) when is_list(opts) do
    learned = Keyword.get(opts, :learned_for_agents)
    issues = Keyword.get(opts, :had_issues)
    improvements = Keyword.get(opts, :improvements)
    info_needed = Keyword.get(opts, :info_needed)
    guidance_useful = Keyword.get(opts, :guidance_useful)

    signal = feedback_signal(guidance_useful, learned, issues, improvements, info_needed)

    event = %{
      "_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "message" => @event_feedback,
      "event" => @event_feedback,
      "severity" => "INFO",
      "level" => "info",
      "service" => "steward_acs",
      "module" => "Acs.Observability.AgentOps",
      "tool_name" => "submit_task_feedback",
      "tool_family" => "task",
      "signal" => signal,
      "agent_id" => Keyword.get(opts, :agent_id),
      "org" => Keyword.get(opts, :org),
      "audience" => normalize_audience(Keyword.get(opts, :audience)),
      "task_id" => Keyword.get(opts, :task_id),
      "guidance_useful" => guidance_useful,
      "has_learned" => present?(learned),
      "has_issues" => present?(issues),
      "has_improvements" => present?(improvements),
      "has_info_needed" => present?(info_needed),
      "info_needed" => truncate(info_needed, 500),
      "learned_for_agents" => truncate(learned, 500),
      "had_issues" => truncate(issues, 500),
      "improvements" => truncate(improvements, 500)
    }

    enqueue_axiom(event)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Log one hybrid memory search impression (features for weight learning).

  Pair later with outcome labels (`guidance_useful`, memory id used in a packet,
  empty→save) keyed by `weight_version` + query/time window.

  ## Options
  - `:query`, `:result_count`, `:weight_version`, `:weights`, `:top_results`
  - `:org`, `:audience`, `:scope_path`
  """
  def log_search(opts) when is_list(opts) do
    result_count = Keyword.get(opts, :result_count, 0)

    event = %{
      "_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "message" => @event_search,
      "event" => @event_search,
      "severity" => "INFO",
      "level" => "info",
      "service" => "steward_acs",
      "module" => "Acs.Observability.AgentOps",
      "call_type" => "search",
      "tool_family" => "retrieve",
      "signal" => if(result_count == 0, do: "gap_empty", else: "works"),
      "query" => truncate(Keyword.get(opts, :query), 200),
      "result_count" => result_count,
      "weight_version" => Keyword.get(opts, :weight_version),
      "weights" => stringify_weights(Keyword.get(opts, :weights)),
      "top_results" => Keyword.get(opts, :top_results) || [],
      "org" => Keyword.get(opts, :org) || safe_org(),
      "audience" => normalize_audience(Keyword.get(opts, :audience)),
      "scope_path" => Keyword.get(opts, :scope_path)
    }

    enqueue_axiom(event)
    :ok
  rescue
    _ -> :ok
  end

  defp stringify_weights(%{} = weights) do
    Map.new(weights, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_weights(_), do: %{}

  @doc """
  Log one Ollama embedding call (latency for agent-space dashboards).

  ## Options
  - `:latency_ms` (required for useful charts)
  - `:status` — `"ok"` | `"error"`
  - `:model`, `:prompt_chars`, `:error_type`, `:org`
  """
  def log_embedding(opts) when is_list(opts) do
    event = %{
      "_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "message" => @event_embedding,
      "event" => @event_embedding,
      "severity" => "INFO",
      "level" => "info",
      "service" => "steward_acs",
      "module" => "Acs.Observability.AgentOps",
      "call_type" => "embedding",
      "tool_family" => "embedding",
      "status" => Keyword.get(opts, :status, "ok"),
      "latency_ms" => Keyword.get(opts, :latency_ms),
      "model" => Keyword.get(opts, :model),
      "provider" => "ollama",
      "prompt_chars" => Keyword.get(opts, :prompt_chars),
      "error_type" => Keyword.get(opts, :error_type),
      "org" => Keyword.get(opts, :org) || safe_org(),
      "audience" => "system"
    }

    enqueue_axiom(event)
    :ok
  rescue
    _ -> :ok
  end

  defp safe_org do
    Acs.Org.current()
  rescue
    _ -> nil
  end

  @doc false
  def tool_family(name, args \\ %{})

  def tool_family(name, args) when is_binary(name) do
    case effective_tool_name(name, args) do
      routed when routed in @retrieve_tools -> "retrieve"
      routed when routed in @write_tools -> "write"
      routed when routed in @task_tools -> "task"
      "steward_ask" -> "retrieve"
      "steward_write" -> "write"
      "steward_work" -> "task"
      _ -> "other"
    end
  end

  def tool_family(_, _), do: "other"

  defp effective_tool_name(name, args) when is_map(args) do
    Acs.MCP.Tools.ChatSurface.routed_tool(name, args) || name
  end

  defp effective_tool_name(name, _), do: name

  @doc false
  def tool_signal(true, _, _, _, _, _, _), do: "misuse_discovery"

  def tool_signal(_, _, _, _, _, _, outcome)
      when outcome in ["needs_input", "needs_scope_choice"],
      do: "intake_gate"

  def tool_signal(_, _, _, _, _, _, "bypass"), do: "intake_bypass"

  def tool_signal(_, "retrieve", true, _, _, _, _), do: "gap_empty"

  def tool_signal(_, "retrieve", _, count, _, _, _) when is_integer(count) and count > 0,
    do: "works"

  def tool_signal(_, "write", _, _, true, _, _), do: "misuse_write"

  def tool_signal(_, "write", _, _, false, true, _), do: "surprise_persist"

  def tool_signal(_, "write", _, _, _, _, _), do: "works"

  def tool_signal(_, _, _, _, _, _, _), do: nil

  @doc false
  def intake_meta(tool_name, result, args \\ %{})

  def intake_meta(tool_name, {:ok, payload}, args)
      when tool_name in @intake_tools and is_map(payload) do
    status = Map.get(payload, :status) || Map.get(payload, "status")
    saved? = Map.get(payload, :saved) || Map.get(payload, "saved")
    intake = Map.get(payload, :intake) || Map.get(payload, "intake") || %{}
    questions = Map.get(payload, :questions) || Map.get(payload, "questions") || []

    question_id =
      case questions do
        [%{"id" => id} | _] -> id
        [%{id: id} | _] -> id
        _ -> nil
      end

    source =
      Map.get(intake, :source) || Map.get(intake, "source")

    sensitive =
      Map.get(payload, :suggested_sensitive) || Map.get(payload, "suggested_sensitive") ||
        Map.get(intake, :suggested_sensitive) || Map.get(intake, "suggested_sensitive")

    notes =
      Map.get(payload, :question) || Map.get(payload, "question") ||
        Map.get(intake, :notes) || Map.get(intake, "notes")

    provider = Map.get(intake, :provider) || Map.get(intake, "provider")
    model = Map.get(intake, :model) || Map.get(intake, "model")

    confirmed? = truthy?(Map.get(args, "intake_confirmed") || Map.get(args, :intake_confirmed))

    outcome =
      cond do
        status in ["needs_input", "needs_scope_choice"] -> status
        confirmed? and (saved? == true or is_binary(status)) -> "bypass"
        saved? == true or status in ["saved", "proposed"] -> "allowed"
        true -> nil
      end

    if outcome do
      %{
        outcome: outcome,
        source: source && to_string(source),
        question_id: question_id,
        suggested_sensitive: truthy?(sensitive),
        notes: notes && to_string(notes) |> String.slice(0, 200),
        provider: provider && to_string(provider),
        model: model && to_string(model)
      }
    else
      %{}
    end
  end

  def intake_meta(_, _, _), do: %{}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("yes"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  @doc false
  def feedback_signal(true, learned, issues, improvements, info_needed) do
    cond do
      present?(learned) -> "win"
      present?(info_needed) -> "gap_info"
      present?(issues) or present?(improvements) -> "pain"
      true -> "works"
    end
  end

  def feedback_signal(_, learned, issues, improvements, info_needed) do
    cond do
      present?(learned) -> "win"
      present?(info_needed) -> "gap_info"
      present?(issues) or present?(improvements) -> "pain"
      true -> nil
    end
  end

  # ── Axiom ───────────────────────────────────────────────────────────────────

  defp enqueue_axiom(event) do
    event = Map.reject(event, fn {_k, v} -> is_nil(v) or v == "" end)

    # Prefer dedicated agent-ops dataset; always mirror to primary logs so data
    # is never lost when steward_meta_analytics is missing or ingest is failing.
    if Process.whereis(Acs.Observability.AgentOpsExporter) do
      AxiomLogExporter.enqueue(event, Acs.Observability.AgentOpsExporter)
    end

    if Process.whereis(AxiomLogExporter) do
      AxiomLogExporter.enqueue(event)
    end

    :ok
  end

  # ── Meta harness (optional local table) ─────────────────────────────────────

  defp maybe_meta_harness(
         tool_name,
         status,
         opts,
         error_type,
         error_message,
         chain_id,
         sequence,
         discovery?
       ) do
    if Acs.MetaHarness.enabled?() and Code.ensure_loaded?(Acs.MetaHarness.OperationLogger) do
      Acs.MetaHarness.OperationLogger.log_async(
        tool_name,
        status_atom(status),
        Keyword.get(opts, :latency_ms),
        error_type,
        error_message && to_string(error_message),
        Keyword.get(opts, :agent_id),
        Keyword.get(opts, :execution_id),
        org: Keyword.get(opts, :org),
        execution_chain_id: chain_id,
        sequence_order: sequence,
        tool_discovered: discovery?,
        params_hash: params_hash(opts, status)
      )
    end
  end

  defp status_atom("success"), do: :success
  defp status_atom("failure"), do: :failure
  defp status_atom("discovery"), do: :discovery
  defp status_atom(_), do: :unknown

  defp params_hash(opts, status) do
    # Compact, non-PII fingerprint agents can group on.
    base =
      "#{Keyword.get(opts, :audience)}|#{status}|#{Keyword.get(opts, :scope_path)}|#{Keyword.get(opts, :kind)}"

    :crypto.hash(:sha256, base) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  # ── Result extraction ───────────────────────────────────────────────────────

  defp result_status({:ok, _}), do: {"success", nil, nil}
  defp result_status(:ok), do: {"success", nil, nil}

  defp result_status({:error, reason}) when is_binary(reason),
    do: {"failure", String.slice(reason, 0, 50), reason}

  defp result_status({:error, %{reason: reason}}),
    do: {"failure", String.slice(to_string(reason), 0, 50), reason}

  defp result_status({:error, reason}),
    do: {"failure", inspect(reason) |> String.slice(0, 50), inspect(reason)}

  defp result_status(other),
    do: {"unknown", "unexpected_result", inspect(other)}

  defp result_count("ask", {:ok, %{summary: summary}}) when is_map(summary) do
    sum_counts(summary)
  end

  defp result_count("query_memories", {:ok, payload}) when is_map(payload) do
    list_len(payload, [:memories, "memories", :results, "results"]) ||
      int_field(payload, [:count, "count"])
  end

  defp result_count("query_specs", {:ok, payload}) when is_map(payload) do
    list_len(payload, [:specs, "specs", :documents, "documents", :results, "results"]) ||
      int_field(payload, [:count, "count"])
  end

  defp result_count("skill_get", {:ok, payload}) when is_map(payload) do
    cond do
      is_list(payload[:skills]) -> length(payload[:skills])
      is_list(payload["skills"]) -> length(payload["skills"])
      is_list(payload[:catalog]) -> length(payload[:catalog])
      is_list(payload["catalog"]) -> length(payload["catalog"])
      is_binary(payload[:name]) or is_binary(payload["name"]) -> 1
      is_list(payload[:results]) -> length(payload[:results])
      true -> nil
    end
  end

  defp result_count("generate_guidance_packet", {:ok, payload}) when is_map(payload) do
    memories =
      list_len(payload, [:relevant_memories, "relevant_memories", :memories, "memories"]) || 0

    skills = list_len(payload, [:relevant_skills, "relevant_skills"]) || 0
    specs = list_len(payload, [:relevant_specs, "relevant_specs"]) || 0
    memories + skills + specs
  end

  defp result_count("list_tasks", {:ok, payload}) when is_map(payload) do
    list_len(payload, [:tasks, "tasks"]) || int_field(payload, [:count, "count"])
  end

  defp result_count(_, _), do: nil

  defp sum_counts(summary) do
    (Map.get(summary, :memory_count) || Map.get(summary, "memory_count") || 0) +
      (Map.get(summary, :document_count) || Map.get(summary, "document_count") || 0) +
      (Map.get(summary, :skill_count) || Map.get(summary, "skill_count") || 0)
  end

  defp list_len(payload, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(payload, key) do
        list when is_list(list) -> length(list)
        _ -> nil
      end
    end)
  end

  defp int_field(payload, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(payload, key) do
        n when is_integer(n) -> n
        _ -> nil
      end
    end)
  end

  defp chain_id(opts) do
    Keyword.get(opts, :execution_id) ||
      Keyword.get(opts, :task_id) ||
      case {Keyword.get(opts, :agent_id), Keyword.get(opts, :org)} do
        {agent, org} when is_binary(agent) and is_binary(org) -> "#{org}:#{agent}"
        {agent, _} when is_binary(agent) -> agent
        _ -> "anon"
      end
  end

  defp next_sequence(chain_id) do
    ensure_seq_table()
    :ets.update_counter(__MODULE__.Seq, chain_id, {2, 1}, {chain_id, 0})
  end

  defp note_chain(chain_id, family, empty_result) do
    ensure_chain_table()

    prev =
      case :ets.lookup(__MODULE__.Chain, chain_id) do
        [{^chain_id, state}] -> state
        [] -> %{seen_retrieve: false, last_empty: false}
      end

    state =
      case family do
        "retrieve" -> %{prev | seen_retrieve: true, last_empty: empty_result == true}
        _ -> prev
      end

    :ets.insert(__MODULE__.Chain, {chain_id, state})
    state
  end

  defp ensure_seq_table do
    case :ets.whereis(__MODULE__.Seq) do
      :undefined ->
        try do
          :ets.new(__MODULE__.Seq, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp ensure_chain_table do
    case :ets.whereis(__MODULE__.Chain) do
      :undefined ->
        try do
          :ets.new(__MODULE__.Chain, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp normalize_audience(nil), do: nil
  defp normalize_audience(a) when a in [:chat, "chat", :knowledge, "knowledge"], do: "chat"
  defp normalize_audience(a) when a in [:coding, "coding", :mcp, "mcp"], do: "coding"
  defp normalize_audience(a), do: to_string(a)

  defp audience_source(nil), do: nil
  defp audience_source(a) when is_atom(a), do: Atom.to_string(a)
  defp audience_source(a) when is_binary(a), do: a
  defp audience_source(_), do: nil

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  defp truncate(nil, _), do: nil
  defp truncate(v, n) when is_binary(v), do: String.slice(v, 0, n)
  defp truncate(v, n), do: v |> inspect() |> String.slice(0, n)
end

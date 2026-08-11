defmodule Acs.LLM do
  @moduledoc """
  LLM wrapper for memory auditor + intake classification.

  Uses shared `LLMUtils.Client` for HTTP calls, provider configs, rate limiting,
  circuit breaking, and response normalization.
  Prompts load via `Acs.Prompts` (org vault override → builtin `priv/prompts/`).
  """

  require Logger

  alias LLMUtils.ResponseParser

  # Provider priority order for evaluations (mimo preferred; nim/minimax optional fallbacks)
  @provider_priority ["mimo", "nim", "minimax", "openai"]

  @doc """
  Evaluates a proposed memory entry for quality, noise, and contradictions.

  Uses JSON wrappers around memory content to protect against prompt injection.

  ## Parameters
    - memory_id: The ID of the memory being evaluated (for logging)
    - memory: Map with :title, :content, :kind, :scope_path, :tags keys

  ## Returns
    - `{:ok, evaluation}` on success with evaluation map
    - `{:error, reason}` on failure

  ## Evaluation Schema
    - `:quality_score` - Integer 1-5 rating of overall content quality
    - `:title_quality` - Integer 1-5 rating of title descriptiveness
    - `:is_noise` - Boolean indicating if memory is pure noise
    - `:recommendation` - String: "approve", "reject", or "human_review"
    - `:reasoning` - String explaining the evaluation
    - `:improvements` - Optional string with suggested improvements
    - `:suggested_title` - Optional improved title
    - `:is_duplicate_of` - Optional ID of duplicate memory if detected
  """
  @spec evaluate_memory(String.t(), map()) :: {:ok, map()} | {:error, atom() | String.t()}
  def evaluate_memory(memory_id, memory) when is_map(memory) do
    with {:ok, _} <- validate_required_fields(memory) do
      do_evaluate_memory(memory_id, memory)
    end
  end

  def evaluate_memory(memory_id, invalid) do
    {:error,
     {:invalid_input, "memory_id #{memory_id}: memory must be a map, got: #{inspect(invalid)}"}}
  end

  # Backward compatibility — deprecated, use evaluate_memory/2
  def evaluate_memory(memory) when is_map(memory) do
    evaluate_memory("unknown", memory)
  end

  def evaluate_memory(invalid) do
    {:error, {:invalid_input, "memory must be a map, got: #{inspect(invalid)}"}}
  end

  @doc """
  Evaluates a skill for actionability, completeness, and description quality.
  """
  @spec evaluate_skill(String.t(), map()) :: {:ok, map()} | {:error, atom() | String.t()}
  def evaluate_skill(skill_name, skill) when is_map(skill) do
    with :ok <- validate_skill_fields(skill) do
      do_evaluate_skill(skill_name, skill)
    end
  end

  def evaluate_skill(skill_name, invalid) do
    {:error,
     {:invalid_input, "skill_name #{skill_name}: skill must be a map, got: #{inspect(invalid)}"}}
  end

  @doc """
  Evaluates a proposed spec or document for quality (approve / reject / human_review).
  """
  @spec evaluate_spec(String.t(), map()) :: {:ok, map()} | {:error, atom() | String.t()}
  def evaluate_spec(spec_id, entry) when is_map(entry) do
    with :ok <- validate_spec_fields(entry) do
      do_evaluate_spec(spec_id, entry)
    end
  end

  def evaluate_spec(spec_id, invalid) do
    {:error,
     {:invalid_input, "spec_id #{spec_id}: entry must be a map, got: #{inspect(invalid)}"}}
  end

  @doc """
  Classify a candidate memory before save (entity, sensitivity, questions).

  Returns raw decoded JSON map from the intake prompt.
  """
  @spec intake_classify(map()) :: {:ok, map()} | {:error, term()}
  def intake_classify(candidate) when is_map(candidate) do
    prompt = build_intake_prompt(candidate)
    providers = get_enabled_providers()

    if providers == [] do
      {:error, :no_providers_enabled}
    else
      try_providers("intake", providers, prompt, nil)
    end
  end

  def intake_classify(invalid) do
    {:error, {:invalid_input, "candidate must be a map, got: #{inspect(invalid)}"}}
  end

  @doc """
  Classify a candidate skill before save (allow / sensitive / quality).

  Single-pass; returns raw decoded JSON from `skills/intake` prompt.
  """
  @spec skill_intake_classify(map()) :: {:ok, map()} | {:error, term()}
  def skill_intake_classify(candidate) when is_map(candidate) do
    prompt = build_skill_intake_prompt(candidate)
    providers = get_enabled_providers()

    if providers == [] do
      {:error, :no_providers_enabled}
    else
      try_providers("skill_intake", providers, prompt, nil)
    end
  end

  def skill_intake_classify(invalid) do
    {:error, {:invalid_input, "candidate must be a map, got: #{inspect(invalid)}"}}
  end

  # ── Validation ────────────────────────────────────────────────────────

  defp validate_required_fields(memory) do
    required = [:title, :content, :kind, :scope_path]

    missing =
      Enum.reduce(required, [], fn field, acc ->
        case Map.get(memory, field) do
          nil -> [field | acc]
          "" -> [field | acc]
          _ -> acc
        end
      end)

    case missing do
      [] -> {:ok, memory}
      _ -> {:error, {:missing_required_fields, Enum.reverse(missing)}}
    end
  end

  # ── Core evaluation logic ───────────────────────────────────────────

  defp validate_skill_fields(skill) do
    missing =
      Enum.reduce([:name, :content], [], fn field, acc ->
        case Map.get(skill, field) do
          nil -> [field | acc]
          "" -> [field | acc]
          _ -> acc
        end
      end)

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_required_fields, Enum.reverse(missing)}}
    end
  end

  defp do_evaluate_memory(memory_id, memory) do
    # Do not send other memories to an external model. Context entries may have
    # narrower ABAC visibility than the proposed memory and are untrusted prompt input.
    prompt = build_evaluation_prompt(memory, [])

    providers = get_enabled_providers()

    if providers == [] do
      {:error, :no_providers_enabled}
    else
      # call_type = process (auditor), subject_id = memory being evaluated
      try_providers("memory_audit", providers, prompt, memory_id)
    end
  end

  defp do_evaluate_skill(skill_name, skill) do
    context = Acs.Skills.Store.context_for_audit(skill.name)
    prompt = build_skill_evaluation_prompt(skill, context)
    providers = get_enabled_providers()

    if providers == [] do
      {:error, :no_providers_enabled}
    else
      try_providers("skill_audit", providers, prompt, skill_name)
    end
  end

  defp validate_spec_fields(entry) do
    missing =
      Enum.reduce([:title], [], fn field, acc ->
        case Map.get(entry, field) do
          nil -> [field | acc]
          "" -> [field | acc]
          _ -> acc
        end
      end)

    # Specs need purpose; documents need content.
    missing =
      cond do
        document_entry?(entry) and blank?(Map.get(entry, :content) || Map.get(entry, "content")) ->
          [:content | missing]

        not document_entry?(entry) and
            blank?(Map.get(entry, :purpose) || Map.get(entry, "purpose")) ->
          [:purpose | missing]

        true ->
          missing
      end

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_required_fields, Enum.reverse(missing)}}
    end
  end

  defp document_entry?(entry) do
    type = Map.get(entry, :document_type) || Map.get(entry, "document_type")
    is_binary(type) and type not in ["", "spec"]
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp do_evaluate_spec(spec_id, entry) do
    # Do not send other entries as prompt context (same harden as memory audit).
    prompt = build_spec_evaluation_prompt(entry, [])
    providers = get_enabled_providers()

    if providers == [] do
      {:error, :no_providers_enabled}
    else
      try_providers("spec_audit", providers, prompt, spec_id)
    end
  end

  # ── Provider iteration ──────────────────────────────────────────────
  # Tries providers in priority order until one succeeds.
  # Uses LLMUtils.Client for the actual HTTP call.
  # call_type = calling process (memory_audit, skill_audit, …); subject_id = entity.

  defp try_providers(call_type, providers, prompt, subject_id) do
    try_providers(call_type, providers, prompt, subject_id, [], byte_size(prompt))
  end

  defp try_providers(_call_type, [], _prompt, _subject_id, errors, _prompt_chars) do
    {:error, {:all_providers_failed, errors |> Enum.reverse() |> Enum.take(3)}}
  end

  defp try_providers(call_type, [provider_id | rest], prompt, subject_id, errors, prompt_chars) do
    # Start is debug-only — do not tag action: "llm_call" (dashboard counts those).
    Logger.debug("[Acs.LLM] Trying provider: #{provider_id}",
      provider: provider_id,
      llm_event: "chat",
      status: "start",
      call_type: call_type
    )

    case call_provider(provider_id, prompt, call_type, prompt_chars, subject_id) do
      {:ok, evaluation} ->
        {:ok, evaluation}

      {:error, reason} ->
        # call_provider already logged the failure with model/latency — don't double-count.
        try_providers(
          call_type,
          rest,
          prompt,
          subject_id,
          [{provider_id, reason} | errors],
          prompt_chars
        )
    end
  end

  # ── Provider call ────────────────────────────────────────────────────
  # Uses LLMUtils.Client with options for metrics, rate limiting, logging.

  defp call_provider(provider_id, prompt, call_type, prompt_chars, subject_id) do
    config = LLMUtils.Providers.get(provider_id)

    if is_nil(config) do
      {:error, :unknown_provider}
    else
      api_key = resolve_api_key(provider_id)

      messages = [%{role: "user", content: prompt}]

      model =
        provider_overrides(provider_id, :model) ||
          config.default_model

      base_url =
        provider_overrides(provider_id, :base_url)

      opts = [
        model: model,
        api_key: api_key,
        json_mode: config.supports_json_mode,
        suppress_thinking: Map.get(config, :suppress_thinking, false),
        max_tokens: 4096,
        temperature: 0.0,
        enable_rate_limiter: true,
        enable_circuit_breaker: false,
        enable_metrics: true
      ]

      opts = if base_url, do: Keyword.put(opts, :base_url, base_url), else: opts

      started = System.monotonic_time(:millisecond)

      case LLMUtils.Client.chat_completion(messages, provider_id, opts) do
        {:ok, %{content: content} = response} ->
          latency_ms = System.monotonic_time(:millisecond) - started

          Logger.info("[Acs.LLM] Provider #{provider_id} ok",
            provider: provider_id,
            model: model,
            latency_ms: latency_ms,
            llm_event: "chat",
            status: "ok",
            action: "llm_call",
            call_type: call_type,
            subject_id: subject_id,
            audience: "system",
            prompt_chars: prompt_chars,
            tokens_in: llm_usage(response, :input),
            tokens_out: llm_usage(response, :output)
          )

          extract_evaluation(content)

        {:ok, response} ->
          latency_ms = System.monotonic_time(:millisecond) - started

          Logger.warning(
            "[Acs.LLM] Unexpected response format from #{provider_id}: #{inspect(response)}",
            provider: provider_id,
            model: model,
            latency_ms: latency_ms,
            llm_event: "chat",
            status: "error",
            action: "llm_call",
            call_type: call_type,
            subject_id: subject_id,
            audience: "system",
            error_type: "unexpected_response_format"
          )

          {:error, :unexpected_response_format}

        {:error, reason} ->
          latency_ms = System.monotonic_time(:millisecond) - started

          Logger.warning("[Acs.LLM] Provider #{provider_id} request failed: #{inspect(reason)}",
            provider: provider_id,
            model: model,
            latency_ms: latency_ms,
            llm_event: "chat",
            status: "error",
            action: "llm_call",
            call_type: call_type,
            subject_id: subject_id,
            audience: "system",
            error_type: normalize_error_type(reason)
          )

          {:error, reason}
      end
    end
  end

  @doc false
  def usage_tokens(response) when is_map(response) do
    usage = Map.get(response, :usage) || Map.get(response, "usage") || %{}

    tokens_in =
      Map.get(usage, :tokens_in) || Map.get(usage, "tokens_in") ||
        Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") ||
        Map.get(usage, :prompt_tokens) || Map.get(usage, "prompt_tokens")

    tokens_out =
      Map.get(usage, :tokens_out) || Map.get(usage, "tokens_out") ||
        Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") ||
        Map.get(usage, :completion_tokens) || Map.get(usage, "completion_tokens")

    total =
      Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") ||
        case {tokens_in, tokens_out} do
          {a, b} when is_integer(a) and is_integer(b) -> a + b
          _ -> nil
        end

    {tokens_in, tokens_out, total}
  end

  def usage_tokens(_), do: {nil, nil, nil}

  @doc false
  def normalize_error_type(:timeout), do: "timeout"
  def normalize_error_type({:timeout, _}), do: "timeout"
  def normalize_error_type({:rate_limited, _, _}), do: "rate_limited"
  def normalize_error_type({:rate_limited, _}), do: "rate_limited"

  def normalize_error_type({:server_error, status, body}) when is_binary(body) do
    cond do
      status in [429] -> "rate_limited"
      String.contains?(body, "ResourceExhausted") -> "capacity"
      status in 500..599 -> "server_error"
      true -> "server_error"
    end
  end

  def normalize_error_type({:server_error, status, _}) when status in 500..599, do: "server_error"
  def normalize_error_type(reason) when is_atom(reason), do: Atom.to_string(reason)

  def normalize_error_type(reason),
    do: reason |> inspect() |> String.slice(0, 200)

  defp llm_usage(response, which) do
    {tokens_in, tokens_out, _} = usage_tokens(response)

    case which do
      :input -> tokens_in
      :output -> tokens_out
    end
  end

  # Allow OpenAI-compatible providers to override base_url and model via env vars.
  # OPENAI_BASE_URL — override the API endpoint (e.g., http://localhost:8000/v1)
  # OPENAI_MODEL   — override the model name (e.g., gpt-4o-mini, local-model)
  defp provider_overrides("openai", :base_url),
    do: System.get_env("OPENAI_BASE_URL") || Application.get_env(:steward_acs, :openai_base_url)

  defp provider_overrides("openai", :model),
    do: System.get_env("OPENAI_MODEL") || Application.get_env(:steward_acs, :openai_model)

  defp provider_overrides(_, _), do: nil

  # ── API key resolution ───────────────────────────────────────────────
  # Checks Application config first (set in runtime.exs), then system env.

  defp resolve_api_key(provider_id) do
    Application.get_env(:steward_acs, :"#{provider_id}_api_key") ||
      System.get_env(LLMUtils.Provider.env_key(provider_id))
  end

  # ── Evaluation extraction ────────────────────────────────────────────

  defp extract_evaluation(content) when is_map(content) do
    {:ok, content}
  end

  defp extract_evaluation(content) when is_binary(content) do
    content
    |> String.trim()
    |> strip_thinking_tags()
    |> ResponseParser.parse()
    |> case do
      {:ok, _} = success -> success
      {:error, _} -> {:error, :invalid_json_response}
    end
  end

  defp extract_evaluation(_), do: {:error, :invalid_json_response}

  # ── Public JSON extraction (backward compat, used in tests) ──────────

  @doc false
  def extract_json_content(nil), do: :error

  def extract_json_content(content) when is_binary(content) do
    content
    |> String.trim()
    |> strip_thinking_tags()
    |> ResponseParser.parse()
    |> case do
      {:ok, _} = success -> success
      _ -> :error
    end
  end

  def extract_json_content(_), do: :error

  # ── Thinking tag stripping ──────────────────────────────────────────
  # Reasoning model responses may include <thinking>...</thinking> blocks.
  # The shared LLMUtils.Client strips these from HTTP responses, but
  # we also strip from raw content as a safety net.

  defp strip_thinking_tags(content) do
    String.replace(content, ~r/<thinking>[\s\S]*?<\/thinking>/i, "")
    |> String.trim()
  end

  # ── Provider filtering ──────────────────────────────────────────────
  # Checks which providers are enabled (whitelist) and have valid API keys.

  defp get_enabled_providers do
    @provider_priority
    |> Enum.filter(&provider_enabled?/1)
    |> Enum.filter(&has_valid_api_key?/1)
  end

  defp provider_enabled?(provider_id) do
    enabled = Application.get_env(:steward_acs, :enabled_llm_providers, [])
    enabled == [] or provider_id in enabled
  end

  defp has_valid_api_key?(provider_id) do
    api_key = resolve_api_key(provider_id)
    is_binary(api_key) and api_key != ""
  end

  # ── Evaluation prompts ──────────────────────────────────────────────
  # Prompts are loaded from priv/prompts/<category>/<name>.md (or vault overrides).
  # No hardcoded fallback — creates a prompt file if one is missing.
  # Two variants per type: "evaluate" (coding audience) and "evaluate_chat" (chat audience).

  defp prompt_name_for_audience(audience) do
    if audience == "chat", do: "evaluate_chat", else: "evaluate"
  end

  defp load_prompt!(category, name) do
    case Acs.Prompts.load(category, name) do
      nil ->
        raise "Missing #{category}/#{name} evaluation prompt. Create priv/prompts/#{category}/#{name}.md"

      template ->
        template
    end
  end

  defp build_skill_evaluation_prompt(skill, context_skills) do
    skill_json =
      Jason.encode!(%{
        audience: skill.audience || "coding",
        name: skill.name || "",
        description: skill.description || "",
        content: skill.content || "",
        tags: skill.tags || []
      })

    existing_skills_json = Jason.encode!(context_skills)
    prompt_name = prompt_name_for_audience(skill.audience)
    template = load_prompt!("skills", prompt_name)

    template
    |> String.replace("{{skill_json}}", skill_json)
    |> String.replace("{{existing_skills_json}}", existing_skills_json)
  end

  defp build_spec_evaluation_prompt(entry, context_entries) do
    entry_json =
      Jason.encode!(%{
        audience: entry.audience || "coding",
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
      })

    existing_entries_json = Jason.encode!(context_entries)
    prompt_name = prompt_name_for_audience(entry.audience)
    template = load_prompt!("specs", prompt_name)

    template
    |> String.replace("{{entry_json}}", entry_json)
    |> String.replace("{{existing_entries_json}}", existing_entries_json)
  end

  defp build_evaluation_prompt(memory, context_memories) do
    memory_json =
      Jason.encode!(%{
        audience: memory.audience || "coding",
        title: memory.title || "",
        content: memory.content || "",
        kind: memory.kind || "",
        scope_path: memory.scope_path || "",
        tags: memory.tags || []
      })

    existing_memories_json = Jason.encode!(context_memories)

    prompt_name = prompt_name_for_audience(memory.audience)

    template =
      case memory_prompt_override() do
        {:ok, content} -> content
        :default -> load_prompt!("memory", prompt_name)
      end

    do_interpolate(template, memory_json, existing_memories_json)
  end

  defp memory_prompt_override do
    with path when is_binary(path) <- System.get_env("MEMORY_EVALUATION_PROMPT_PATH"),
         trimmed when trimmed != "" <- String.trim(path),
         true <- Path.type(trimmed) == :absolute,
         true <- File.exists?(trimmed),
         {:ok, content} <- File.read(trimmed) do
      {:ok, content}
    else
      {:error, reason} ->
        Logger.warning(
          "[Acs.LLM] Failed to read MEMORY_EVALUATION_PROMPT_PATH: #{inspect(reason)}."
        )

        :default

      _ ->
        :default
    end
  end

  defp do_interpolate(template, memory_json, existing_memories_json) do
    template
    |> String.replace("{{memory_json}}", memory_json)
    |> String.replace("{{existing_memories_json}}", existing_memories_json)
  end

  defp build_intake_prompt(candidate) do
    template = load_prompt!("memory", "intake")

    candidate_json =
      Jason.encode!(%{
        title: Map.get(candidate, "title") || Map.get(candidate, :title),
        content: Map.get(candidate, "content") || Map.get(candidate, :content),
        kind: Map.get(candidate, "kind") || Map.get(candidate, :kind),
        scope_path: Map.get(candidate, "scope_path") || Map.get(candidate, :scope_path),
        visibility: Map.get(candidate, "visibility") || Map.get(candidate, :visibility),
        confidential: Map.get(candidate, "confidential") || Map.get(candidate, :confidential),
        about_type: Map.get(candidate, "about_type") || Map.get(candidate, :about_type),
        about_name: Map.get(candidate, "about_name") || Map.get(candidate, :about_name),
        about_email: Map.get(candidate, "about_email") || Map.get(candidate, :about_email),
        audience:
          Map.get(candidate, "_auth_audience") || Map.get(candidate, "audience") ||
            Map.get(candidate, :audience)
      })

    String.replace(template, "{{candidate_json}}", candidate_json)
  end

  defp build_skill_intake_prompt(candidate) do
    template = load_prompt!("skills", "intake")

    candidate_json =
      Jason.encode!(%{
        name: Map.get(candidate, "name") || Map.get(candidate, :name),
        description: Map.get(candidate, "description") || Map.get(candidate, :description),
        when_to_use: Map.get(candidate, "when_to_use") || Map.get(candidate, :when_to_use),
        content: Map.get(candidate, "content") || Map.get(candidate, :content),
        tags: Map.get(candidate, "tags") || Map.get(candidate, :tags) || [],
        scope_paths: Map.get(candidate, "scope_paths") || Map.get(candidate, :scope_paths) || [],
        audience:
          Map.get(candidate, "_auth_audience") || Map.get(candidate, "audience") ||
            Map.get(candidate, :audience)
      })

    String.replace(template, "{{candidate_json}}", candidate_json)
  end
end

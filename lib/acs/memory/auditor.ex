defmodule Acs.Memory.Auditor do
  @moduledoc """
  GenServer that periodically audits proposed memory entries for quality,
  noise, contradictions, and title quality using LLM evaluation.

  Polls every configured interval (default 30 seconds) for proposed memories
  that have passed their cooling-off period across **all orgs** (GenServer has
  no request org). Skips rows already parked for human review or hard audit
  errors. Each memory goes through:
  1. Cooling-off check (skip if created_at < 30s ago)
  2. Parse error skip (skip if status is parse_error)
  3. Pre-filter rules (auto-generated task feedback templates, test data patterns, 
      content length, empty scope, title==content, duplicates)
  4. LLM evaluation with context from same-scope approved memories
  5. Decision: approve / reject / human_review
  6. DB + vault update (approve/reject write YAML so VaultSweeper does not revert)

  Concurrent LLM evaluations controlled by `AUDITOR_MAX_CONCURRENCY` (default 20).
  Provider rate limiters naturally cap actual throughput — the NIM limit of 40 req/min
  is the binding constraint, so higher concurrency just absorbs response time variance.
  Retries failed ones up to 3 times with exponential backoff (2s, 5s, 15s).
  """

  use GenServer
  require Logger

  alias Acs.LLM
  alias Acs.Memory.Indexer
  alias Acs.Memory.Schema
  alias Acs.Observability.Events
  alias Acs.Repo

  # Default polling interval: 30 seconds
  @default_audit_interval 30_000

  # Cooling-off period: 30 seconds
  @cooling_off_seconds 30

  # Max concurrent LLM evaluations via Task.async_stream.
  # Provider rate limiters (NIM: 40/min, Mimo: 100/min) are the binding constraint,
  # so this should be set high enough to keep the pipeline saturated under variance.
  # Configurable via AUDITOR_MAX_CONCURRENCY env var.
  @default_max_concurrency 20

  # Retry configuration
  @max_retries 3

  # Exponential backoff delays in milliseconds (longer for production resilience)
  @backoff_delays [2_000, 5_000, 15_000, 30_000, 60_000]

  # Pre-filter thresholds (overridable via Application config)
  @default_min_content_length 20
  @default_low_content_length 50
  @default_fuzzy_threshold 0.85
  @default_reject_title_prefixes ["Key learning from task", "Issue encountered in task"]
  @default_reject_title_exact ["Improvement suggestion from task feedback"]
  @default_reject_scope_prefixes ["test/", "test_app/"]
  @default_reject_id_prefixes ["lifecycle_rebuild"]
  @default_reject_id_contains ["guidance_test", "e2e_pipeline", "test_hybrid"]

  @doc """
  Starts the Auditor GenServer.
  """
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Manually triggers an audit cycle. Useful for testing or on-demand evaluation.
  """
  def trigger_audit do
    GenServer.cast(__MODULE__, :trigger_audit)
  end

  @doc """
  Returns the current audit interval configuration.
  """
  def audit_interval do
    Application.get_env(:steward_acs, :auditor_interval, @default_audit_interval)
  end

  @impl true
  def init(_opts) do
    interval = audit_interval()
    Logger.info("[Acs.Memory.Auditor] Starting with interval: #{interval}ms")
    Acs.IdleTracker.subscribe()
    schedule_audit(interval)
    {:ok, %{audit_in_progress: false}}
  end

  @impl true
  def handle_info(:audit, %{audit_in_progress: true} = state) do
    Logger.debug("[Acs.Memory.Auditor] Audit already in progress, skipping")
    {:noreply, state}
  end

  @impl true
  def handle_info(:activity, state) do
    Logger.debug("[Acs.Memory.Auditor] Activity detected, waking to fast cadence")
    schedule_audit(audit_interval())
    {:noreply, state}
  end

  @impl true
  def handle_info(:audit, state) do
    if Acs.IdleTracker.idle?() do
      Logger.debug("[Acs.Memory.Auditor] Idle, sleeping")
      schedule_audit(Acs.IdleTracker.sleep_interval_ms())
      {:noreply, state}
    else
      state = %{state | audit_in_progress: true}

      try do
        do_audit_cycle()
      after
        # Always reset flag and reschedule, even on crash
        schedule_audit(audit_interval())
      end

      {:noreply, %{state | audit_in_progress: false}}
    end
  end

  @impl true
  def handle_cast(:trigger_audit, %{audit_in_progress: true} = state) do
    Logger.info("[Acs.Memory.Auditor] Audit already in progress, ignoring manual trigger")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:trigger_audit, state) do
    Logger.info("[Acs.Memory.Auditor] Manual audit triggered")
    state = %{state | audit_in_progress: true}

    try do
      do_audit_cycle()
    after
      # Reset flag but don't reschedule (manual trigger)
    end

    {:noreply, %{state | audit_in_progress: false}}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # Schedules the next audit cycle
  defp schedule_audit(interval) do
    Process.send_after(self(), :audit, interval)
  end

  # Main audit cycle logic
  defp do_audit_cycle do
    Logger.info("[Acs.Memory.Auditor] Starting audit cycle")
    start_time = DateTime.utc_now()

    {proposed_memories, skipped} = fetch_auditable_memories()

    by_org =
      proposed_memories
      |> Enum.frequencies_by(& &1.org)
      |> Enum.map_join(", ", fn {org, n} -> "#{org}=#{n}" end)

    Logger.info(
      "[Acs.Memory.Auditor] Found #{length(proposed_memories)} memories to audit (concurrency: #{audit_max_concurrency()}) orgs=[#{by_org}]"
    )

    Events.info("memory_auditor.cycle",
      component: "memory_auditor",
      audit_event: "cycle",
      count: length(proposed_memories),
      skipped: skipped,
      orgs: by_org
    )

    if proposed_memories == [] do
      :ok
    else
      max_conc = audit_max_concurrency()

      # Process with max concurrency via Task.async_stream
      proposed_memories
      |> Task.async_stream(fn memory -> audit_memory_with_retry(memory) end,
        max_concurrency: max_conc,
        timeout: :infinity
      )
      |> Enum.each(fn
        {:ok, result} -> result
        {:error, reason} -> Logger.error("[Acs.Memory.Auditor] Task error: #{inspect(reason)}")
      end)
    end

    end_time = DateTime.utc_now()
    duration = DateTime.diff(end_time, start_time, :millisecond)
    Logger.info("[Acs.Memory.Auditor] Audit cycle completed in #{duration}ms")
  end

  # Fetches proposed memories that have passed cooling-off and are not parse_error.
  # Multi-tenant: GenServer has no request org, so scan all orgs (VaultSweeper pattern).
  defp auditable_kinds, do: Acs.Memory.auditable_kinds()

  defp fetch_auditable_memories do
    cooling_off_threshold = DateTime.utc_now() |> DateTime.add(-@cooling_off_seconds, :second)

    memories =
      Indexer.list_memories(
        status: "proposed",
        order_by: [asc: :created_at],
        limit: 200,
        org: :all,
        system: true
      )
      |> Enum.reject(fn m -> !(m.kind in auditable_kinds()) end)
      |> Enum.reject(fn m -> m.parse_error && m.parse_error != "" end)

    {memories, skipped} =
      Enum.reduce(memories, {[], %{}}, fn memory, {auditable, skipped} ->
        case audit_skip_reason(memory) do
          nil -> {[memory | auditable], skipped}
          reason -> {auditable, Map.update(skipped, reason, 1, &(&1 + 1))}
        end
      end)

    memories =
      memories
      |> Enum.reverse()
      |> Enum.filter(fn m ->
        case m.created_at do
          nil -> false
          dt -> DateTime.compare(coerce_datetime(dt), cooling_off_threshold) == :lt
        end
      end)

    {memories, skipped}
  end

  # Proposed rows with a settled verdict are already handled and must not be
  # re-audited, even if the status transition was interrupted.
  @doc "Returns why a proposed memory should not be audited again, or `nil`."
  @spec audit_skip_reason(map()) :: atom() | nil
  def audit_skip_reason(memory) when is_map(memory) do
    flags = decode_auditor_flags(memory.auditor_flags)
    verdict = Map.get(flags, "audit_verdict")
    error_count = Map.get(flags, "audit_error_count", 0)

    cond do
      verdict in ["approve", "reject", "human_review"] ->
        :settled_verdict

      Map.get(flags, "needs_human_review") == true ->
        :human_review

      is_number(error_count) and error_count > 0 ->
        :audit_error

      # Fuzzy duplicates stay `proposed` on purpose so a human can make the call,
      # but nothing else moves them off that status — without this they came back
      # every cycle and were re-flagged forever.
      is_binary(Map.get(flags, "flagged_reason")) ->
        :flagged

      true ->
        nil
    end
  end

  defp coerce_datetime(%DateTime{} = dt), do: dt

  defp coerce_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  # Audits a single memory with retry logic
  defp audit_memory_with_retry(memory) do
    memory_id = memory.id
    with_retries(memory_id, memory, @max_retries, @backoff_delays)
  end

  # Retry wrapper with exponential backoff
  defp with_retries(memory_id, _memory, 0, _delays) do
    Logger.warning("[Acs.Memory.Auditor] Max retries exceeded for memory #{memory_id}")
    increment_audit_error(memory_id, "Max retries exceeded")
    :max_retries_exceeded
  end

  # When retries are exhausted AND providers are truly unavailable (not just temporarily failing),
  # mark the memory for human_review so it doesn't keep being retried
  defp with_retries(memory_id, memory, retries_left, [delay | rest_delays]) do
    case audit_single_memory(memory) do
      :ok ->
        :ok

      {:error, reason} ->
        case classify_provider_failure(reason) do
          :permanent ->
            Logger.warning(
              "[Acs.Memory.Auditor] LLM providers unavailable for #{memory_id}, marking for human review"
            )

            mark_for_human_review_after_max_retries(memory_id, inspect(reason))
            :ok

          :transient_exhausted ->
            # All providers already failed this attempt — don't sleep×N. Leave proposed
            # for the next audit cycle once mimo/nim recovers.
            Logger.warning(
              "[Acs.Memory.Auditor] All providers failed for #{memory_id}; deferring to next cycle"
            )

            :ok

          :retryable ->
            Logger.warning(
              "[Acs.Memory.Auditor] Audit failed for #{memory_id}: #{inspect(reason)}. Retrying in #{delay}ms"
            )

            Process.sleep(delay)
            with_retries(memory_id, memory, retries_left - 1, rest_delays)
        end
    end
  end

  # Detect if the error is caused by missing LLM API keys (provider unavailability).
  # all_providers_failed = every provider already tried this round — stop retries,
  # but leave the memory proposed for the next cycle (not human_review).
  defp classify_provider_failure(:no_providers_enabled), do: :permanent
  defp classify_provider_failure({:all_providers_failed, _errors}), do: :transient_exhausted
  defp classify_provider_failure(_), do: :retryable

  # Mark memory for human review after max retries when providers are truly unavailable
  defp mark_for_human_review_after_max_retries(memory_id, reason) do
    import Ecto.Query
    alias Acs.Memory.Schema
    alias Acs.Repo

    case Repo.get(Schema, memory_id) do
      nil ->
        Logger.error("[Acs.Memory.Auditor] Memory not found: #{memory_id}")

      memory ->
        existing_flags = decode_auditor_flags(memory.auditor_flags)

        merged_flags =
          existing_flags
          |> Map.merge(%{
            "audit_error_count" => Map.get(existing_flags, "audit_error_count", 0) + 1,
            "last_audit_error" => "Providers unavailable: #{reason}",
            "last_audit_error_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "needs_human_review" => true,
            "human_review_reason" => "LLM providers unavailable after max retries"
          })

        flags_json = Jason.encode!(merged_flags)

        Repo.update_all(
          from(m in Schema, where: m.id == ^memory_id),
          set: [
            auditor_flags: flags_json,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

        Logger.info(
          "[Acs.Memory.Auditor] Memory #{memory_id} marked for human review (providers unavailable)"
        )
    end
  rescue
    e ->
      Logger.error(
        "[Acs.Memory.Auditor] Failed to mark memory #{memory_id} for human review: #{inspect(e)}"
      )
  end

  # Audits a single memory through the full pipeline
  defp audit_single_memory(memory) do
    memory_id = memory.id

    # Step 1: Pre-filter checks
    case pre_filter_check(memory) do
      {:skip, reason} ->
        Logger.debug("[Acs.Memory.Auditor] Pre-filter skip for #{memory_id}: #{reason}")
        :ok

      :continue ->
        # Step 2: Build memory attrs for LLM
        memory_attrs = build_memory_attrs(memory)

        # Step 3: LLM evaluation
        case LLM.evaluate_memory(memory_id, memory_attrs) do
          {:ok, evaluation} ->
            # Step 4: Apply decision
            apply_audit_decision(memory_id, evaluation)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp audit_max_concurrency do
    Application.get_env(:steward_acs, :auditor_max_concurrency, @default_max_concurrency)
  end

  # ── Config-driven pre-filter helpers ─────────────────────────────────

  defp min_content_length do
    Application.get_env(:steward_acs, :auditor_min_content_length, @default_min_content_length)
  end

  defp low_content_length do
    Application.get_env(:steward_acs, :auditor_low_content_length, @default_low_content_length)
  end

  defp fuzzy_threshold do
    Application.get_env(:steward_acs, :auditor_fuzzy_threshold, @default_fuzzy_threshold)
  end

  defp reject_title_prefixes do
    Application.get_env(
      :steward_acs,
      :auditor_reject_title_prefixes,
      @default_reject_title_prefixes
    )
  end

  defp reject_title_exact do
    Application.get_env(:steward_acs, :auditor_reject_title_exact, @default_reject_title_exact)
  end

  defp reject_scope_prefixes do
    Application.get_env(
      :steward_acs,
      :auditor_reject_scope_prefixes,
      @default_reject_scope_prefixes
    )
  end

  defp reject_id_prefixes do
    Application.get_env(:steward_acs, :auditor_reject_id_prefixes, @default_reject_id_prefixes)
  end

  defp reject_id_contains do
    Application.get_env(:steward_acs, :auditor_reject_id_contains, @default_reject_id_contains)
  end

  defp reject_empty_scope? do
    Application.get_env(:steward_acs, :auditor_reject_empty_scope, true)
  end

  defp reject_title_equals_content? do
    Application.get_env(:steward_acs, :auditor_reject_title_equals_content, true)
  end

  # Pre-filter check returns {:skip, reason} or :continue
  defp pre_filter_check(memory) do
    cond do
      # Auto-generated task feedback template → reject
      match_reject_title_prefix?(memory.title) or
          match_reject_title_exact?(memory.title) ->
        mark_as_rejected(memory.id, "Auto-generated task feedback template")
        {:skip, "auto-generated task feedback"}

      # Test/harness data by scope pattern → reject
      match_reject_scope_prefix?(memory.scope_path) ->
        mark_as_rejected(memory.id, "Test/harness scope_path")
        {:skip, "test scope_path"}

      # Test/harness data by known ID patterns → reject
      match_reject_id_pattern?(memory.id) ->
        mark_as_rejected(memory.id, "Test/harness data by ID pattern")
        {:skip, "test data by id"}

      # Empty scope → reject
      reject_empty_scope?() and (is_nil(memory.scope_path) or memory.scope_path == "") ->
        mark_as_rejected(memory.id, "Empty scope_path")
        {:skip, "empty scope"}

      # Title equals content → reject
      reject_title_equals_content?() and memory.title == memory.content ->
        mark_as_rejected(memory.id, "Title same as content")
        {:skip, "title equals content"}

      # Content too short → flag for human review
      content_length(memory.content) < min_content_length() ->
        mark_needs_human_review(
          memory.id,
          "Content too short (#{content_length(memory.content)} chars)"
        )

        {:skip, "content too short"}

      # Content borderline → flag + proceed with LLM
      content_length(memory.content) < low_content_length() ->
        Logger.debug(
          "[Acs.Memory.Auditor] Memory #{memory.id} has short content (#{content_length(memory.content)} chars), flagging for LLM review"
        )

        :continue

      # Check for fuzzy duplicates
      true ->
        case find_fuzzy_duplicate(memory) do
          nil ->
            :continue

          duplicate_id ->
            mark_flagged(memory.id, "Possible duplicate of #{duplicate_id}")
            {:skip, "fuzzy duplicate detected"}
        end
    end
  end

  defp match_reject_title_prefix?(title) do
    Enum.any?(reject_title_prefixes(), &String.starts_with?(title || "", &1))
  end

  defp match_reject_title_exact?(title) do
    title in reject_title_exact()
  end

  defp match_reject_scope_prefix?(scope_path) do
    Enum.any?(reject_scope_prefixes(), &String.starts_with?(scope_path || "", &1))
  end

  defp match_reject_id_pattern?(id) when is_binary(id) do
    id_lower = String.downcase(id)

    Enum.any?(reject_id_prefixes(), &String.starts_with?(id_lower, &1)) or
      Enum.any?(reject_id_contains(), &String.contains?(id_lower, &1))
  end

  defp match_reject_id_pattern?(_), do: false

  defp content_length(nil), do: 0
  defp content_length(content) when is_binary(content), do: String.length(content)

  # Find potential fuzzy duplicate by title similarity (same org only)
  defp find_fuzzy_duplicate(memory) do
    candidates =
      Indexer.list_memories(
        scope_path: memory.scope_path,
        status: "approved",
        limit: 20,
        org: memory.org || Acs.Org.current(),
        system: true
      )

    memory_title = String.downcase(memory.title || "")

    duplicate =
      Enum.find(candidates, fn candidate ->
        candidate_title = String.downcase(candidate.title || "")

        candidate_title != "" &&
          memory_title != "" &&
          String.jaro_distance(memory_title, candidate_title) > fuzzy_threshold()
      end)

    duplicate && duplicate.id
  end

  # Build atom-keyed map for LLM evaluation
  defp build_memory_attrs(memory) do
    %{
      audience: memory.audience || "coding",
      title: memory.title || "",
      content: memory.content || "",
      kind: memory.kind || "",
      scope_path: memory.scope_path || "",
      tags: decode_tags(memory.tags_json)
    }
  end

  defp decode_tags(nil), do: []

  defp decode_tags(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, tags} -> tags
      _ -> []
    end
  end

  # Apply the LLM evaluation decision to the memory
  defp apply_audit_decision(memory_id, evaluation) do
    # Parse: extract recommendation from string-keyed map (already normalized by LLM parser),
    # fall back to atom keys for safety, then default to "human_review" because the pre-filter
    # already catches noise (task feedback templates, test data, empty scope, title==content, etc).
    # If LLM fails (e.g., query timeout), default to human_review to avoid auto-approving junk.
    recommendation = evaluation["recommendation"] || evaluation[:recommendation] || "human_review"

    auditor_flags = %{
      audit_verdict: recommendation,
      quality_score: Map.get(evaluation, "quality_score") || Map.get(evaluation, :quality_score),
      title_quality: Map.get(evaluation, "title_quality") || Map.get(evaluation, :title_quality),
      is_noise: Map.get(evaluation, "is_noise") || Map.get(evaluation, :is_noise),
      reasoning: Map.get(evaluation, "reasoning") || Map.get(evaluation, :reasoning),
      improvements: Map.get(evaluation, "improvements"),
      suggested_title: Map.get(evaluation, "suggested_title"),
      is_duplicate_of: Map.get(evaluation, "is_duplicate_of"),
      audited_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    result =
      case recommendation do
        "approve" ->
          case Repo.get(Schema, memory_id) do
            nil ->
              {:error, "Memory not found: #{memory_id}"}

            memory ->
              flags =
                memory
                |> apply_suggested_title(evaluation, auditor_flags)
                |> then(&apply_improvements(memory, evaluation, &1))

              update_memory_status(memory_id, "approved", flags)
          end

        "reject" ->
          update_memory_status(memory_id, "rejected", auditor_flags)

        _ ->
          # human_review or any other value
          mark_needs_human_review_with_flags(memory_id, auditor_flags)
      end

    result
  end

  defp apply_suggested_title(memory, evaluation, flags) do
    suggested = Map.get(evaluation, "suggested_title") || Map.get(evaluation, :suggested_title)
    public_id = Indexer.public_id(memory.id, memory.org)

    if suggested && is_binary(suggested) && String.trim(suggested) != "" &&
         String.trim(suggested) != memory.title do
      case Acs.Memory.Store.revise(public_id, %{title: String.trim(suggested)},
             org: memory.org,
             actor: %{type: "system", id: "memory_auditor"},
             source: "auditor",
             message: "Memory auditor improved title",
             metadata: %{auditor_flags: flags}
           ) do
        {:ok, _} ->
          Logger.info(
            "[Acs.Memory.Auditor] Auto-improved title for #{memory.id}: '#{memory.title}' → '#{String.trim(suggested)}'"
          )

          Map.merge(flags, %{
            title_improved: true,
            previous_title: memory.title,
            new_title: String.trim(suggested)
          })

        {:error, reason} ->
          Logger.error(
            "[Acs.Memory.Auditor] Failed to apply suggested_title for #{memory.id}: #{inspect(reason)}"
          )

          flags
      end
    else
      flags
    end
  end

  defp apply_improvements(memory, evaluation, flags) do
    improvements = Map.get(evaluation, "improvements") || Map.get(evaluation, :improvements)
    public_id = Indexer.public_id(memory.id, memory.org)

    if improvements && is_binary(improvements) && String.trim(improvements) != "" do
      # Re-read content in case title path already mutated the row.
      content =
        case Indexer.get_memory(public_id, memory.org) do
          %{content: c} when is_binary(c) -> c
          _ -> memory.content
        end

      new_content = content <> "\n\n---\nImprovements: " <> String.trim(improvements)

      case Acs.Memory.Store.revise(public_id, %{content: new_content},
             org: memory.org,
             actor: %{type: "system", id: "memory_auditor"},
             source: "auditor",
             message: "Memory auditor improved content",
             metadata: %{auditor_flags: flags}
           ) do
        {:ok, _} ->
          Logger.info("[Acs.Memory.Auditor] Auto-improved content for #{memory.id}")
          Map.put(flags, :content_improved, true)

        {:error, reason} ->
          Logger.error(
            "[Acs.Memory.Auditor] Failed to apply improvements for #{memory.id}: #{inspect(reason)}"
          )

          flags
      end
    else
      flags
    end
  end

  # Update memory status in DB + vault YAML (storage id is org-qualified in multi-tenant)
  defp update_memory_status(memory_id, new_status, auditor_flags) do
    flags_json = Jason.encode!(auditor_flags)

    case Repo.get(Schema, memory_id) do
      nil ->
        {:error, "Memory not found: #{memory_id}"}

      memory ->
        public_id = Indexer.public_id(memory.id, memory.org)

        with {:ok, _result} <-
               Acs.Memory.Store.transition(public_id, new_status,
                 org: memory.org,
                 actor: %{type: "system", id: "memory_auditor"},
                 source: "auditor",
                 message: "Memory auditor marked #{public_id} #{new_status}",
                 metadata: %{auditor_flags: auditor_flags}
               ) do
          import Ecto.Query

          Repo.update_all(
            from(m in Schema, where: m.id == ^memory_id),
            set: [
              auditor_flags: flags_json,
              updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            ]
          )

          Logger.info("[Acs.Memory.Auditor] Memory #{memory_id} → #{new_status}")
          :ok
        end
    end
  rescue
    e ->
      Logger.error("[Acs.Memory.Auditor] Failed to update memory #{memory_id}: #{inspect(e)}")
      {:error, e}
  end

  # Mark memory as rejected with reason
  defp mark_as_rejected(memory_id, reason) do
    auditor_flags = %{
      audit_verdict: "reject",
      reasoning: "Pre-filter: #{reason}",
      audited_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    update_memory_status(memory_id, "rejected", auditor_flags)
  end

  # Mark memory as needing human review
  defp mark_needs_human_review(memory_id, reason) do
    Logger.info("[Acs.Memory.Auditor] Memory #{memory_id} flagged for human review: #{reason}")
    increment_audit_error(memory_id, "Pre-filter: #{reason}")
  end

  defp mark_needs_human_review_with_flags(memory_id, auditor_flags) do
    import Ecto.Query
    alias Acs.Memory.Schema
    alias Acs.Repo

    # Update auditor_flags with LLM evaluation data AND increment error count via the same update
    case Repo.get(Schema, memory_id) do
      nil ->
        {:error, "Memory not found"}

      memory ->
        existing_flags = decode_auditor_flags(memory.auditor_flags)
        current_count = Map.get(existing_flags, "audit_error_count", 0)

        merged_flags =
          auditor_flags
          |> Map.put("audit_error_count", current_count + 1)
          |> Map.put("last_audit_error", "LLM recommended human_review")
          |> Map.put("last_audit_error_at", DateTime.utc_now() |> DateTime.to_iso8601())

        flags_json = Jason.encode!(merged_flags)
        :ok = record_audit_revision(memory, merged_flags, "Memory auditor requested human review")

        Repo.update_all(
          from(m in Schema, where: m.id == ^memory_id),
          set: [
            auditor_flags: flags_json,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

        Logger.info(
          "[Acs.Memory.Auditor] Memory #{memory_id} → flagged for human review (error #{current_count + 1})"
        )

        :ok
    end
  rescue
    e ->
      Logger.error("[Acs.Memory.Auditor] Failed to flag memory #{memory_id}: #{inspect(e)}")
      {:error, e}
  end

  # Mark memory with a duplicate flag but keep as proposed
  defp mark_flagged(memory_id, reason) do
    import Ecto.Query
    alias Acs.Memory.Schema
    alias Acs.Repo

    case Repo.get(Schema, memory_id) do
      nil ->
        {:error, "Memory not found"}

      memory ->
        existing_flags = decode_auditor_flags(memory.auditor_flags)

        # String keys: existing_flags comes back from Jason.decode, so atom keys
        # here merge alongside rather than over them and Jason emits both.
        merged_flags =
          Map.merge(existing_flags, %{
            "flagged_reason" => reason,
            "flagged_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        flags_json = Jason.encode!(merged_flags)
        :ok = record_audit_revision(memory, merged_flags, "Memory auditor flagged duplicate")

        Repo.update_all(
          from(m in Schema, where: m.id == ^memory_id),
          set: [
            auditor_flags: flags_json,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

        Logger.info("[Acs.Memory.Auditor] Memory #{memory_id} flagged: #{reason}")
        :ok
    end
  rescue
    e ->
      Logger.error("[Acs.Memory.Auditor] Failed to flag memory #{memory_id}: #{inspect(e)}")
      {:error, e}
  end

  defp decode_auditor_flags(nil), do: %{}

  defp decode_auditor_flags(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp record_audit_revision(memory, flags, message) do
    if Acs.Org.multi_tenant?() do
      public_id = Indexer.public_id(memory.id, memory.org)

      case Acs.Memory.Store.revise(public_id, %{},
             org: memory.org,
             actor: %{type: "system", id: "memory_auditor"},
             source: "auditor",
             message: message,
             metadata: %{auditor_flags: flags}
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp increment_audit_error(memory_id, reason) do
    import Ecto.Query
    alias Acs.Memory.Schema
    alias Acs.Repo

    case Repo.get(Schema, memory_id) do
      nil ->
        {:error, "Memory not found"}

      memory ->
        existing_flags = decode_auditor_flags(memory.auditor_flags)
        current_count = Map.get(existing_flags, "audit_error_count", 0)

        updated_flags =
          existing_flags
          |> Map.merge(%{
            "audit_error_count" => current_count + 1,
            "last_audit_error" => reason,
            "last_audit_error_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        flags_json = Jason.encode!(updated_flags)

        case record_audit_revision(
               memory,
               updated_flags,
               "Memory auditor recorded an audit error"
             ) do
          :ok ->
            :ok

          {:error, revision_reason} ->
            Logger.warning(
              "[Acs.Memory.Auditor] Skipped audit revision for #{memory_id}: #{inspect(revision_reason)}"
            )
        end

        Repo.update_all(
          from(m in Schema, where: m.id == ^memory_id),
          set: [
            auditor_flags: flags_json,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

        Logger.info(
          "[Acs.Memory.Auditor] Incremented audit error for #{memory_id} (count: #{current_count + 1})"
        )

        Events.warning("memory_auditor.audit_error",
          component: "memory_auditor",
          audit_event: "audit_error",
          memory_id: memory_id,
          org: memory.org,
          audit_error_count: current_count + 1,
          reason: reason
        )

        :ok
    end
  rescue
    e ->
      Logger.error(
        "[Acs.Memory.Auditor] Failed to increment audit error for #{memory_id}: #{inspect(e)}"
      )

      {:error, e}
  end
end

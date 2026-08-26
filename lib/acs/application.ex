defmodule Acs.Application do
  @moduledoc """
  Starts the ACS supervision tree.

  Multi-tenant deployments do not start filesystem watchers for specs or MCP
  tools; they retain the auditors. Single-tenant deployments retain their
  existing vault-backed watcher behavior.
  """
  use Application

  require Logger

  @impl true
  def prep_stop(state) do
    if axiom_enabled?() and Process.whereis(Acs.Observability.AxiomLogExporter) do
      Acs.Observability.AxiomLogExporter.flush()
    end

    state
  end

  @impl true
  def stop(_state) do
    if Acs.MetaHarness.enabled?(), do: Acs.MetaHarness.OperationLogger.flush()
    :ok
  end

  @impl true
  def start(_type, _args) do
    if axiom_enabled?(), do: setup_observability()
    :ok = Acs.Observability.LiveViewMetrics.attach()
    Acs.MCP.HealthCache.setup()
    Acs.OrgsCache.setup()
    Acs.FileCache.setup()
    :ok = Acs.Org.load_persisted_developer_name()

    meta_harness_children =
      if Acs.MetaHarness.enabled?() and
           Application.get_env(:steward_acs, :start_background_workers, true) do
        [
          # Owns the RecentOps ETS table so it survives short-lived creators crashing.
          Acs.MetaHarness.RecentOps.Table,
          Acs.MetaHarness.OperationLogger,
          Acs.MetaHarness.Scheduler
        ]
      else
        []
      end

    observability_children =
      if axiom_enabled?() do
        [Acs.Observability.AxiomLogExporter, Acs.Observability.VmMetrics] ++
          agent_ops_exporter_children()
      else
        []
      end

    # IdleTracker must be up before LogStore and the MetaHarness Scheduler so
    # they can consult idle?/0 on their first tick. PubSub is prepended last
    # (after the auditor children below) so it starts before every worker that
    # subscribes to idle→active wake broadcasts in its init.
    children =
      [Acs.Apps.Config, Acs.Repo, Acs.IdleTracker] ++
        observability_children ++
        meta_harness_children ++
        [
          Acs.Acs.Cache,
          Acs.Acs.Sweeper,
          Acs.MCP.RateLimitStore,
          Acs.MCP.OAuth.BrokerStore,
          Acs.MCP.BridgeSessionStore,
          Acs.MCP.ClientSession,
          Acs.MCP.ToolRegistry,
          Acs.MCP.SSESessionManager,
          Acs.MCP.LogStore,
          Acs.MCP.ErrorTrace,
          # Acs.MCP.Server removed — endpoint handles MCP routing (start_http/1 available for standalone)
          AcsWeb.Endpoint
        ] ++ log_analyzer_children()

    background_workers? = Application.get_env(:steward_acs, :start_background_workers, true)
    multi_tenant? = Acs.Org.multi_tenant?()

    tools_watcher_children =
      if background_workers? and not multi_tenant? and vault_configured?() do
        [Acs.MCP.Tools.FileWatcher]
      else
        []
      end

    # Only start file watcher and retention sweeper in non-test environments
    # to avoid background tasks conflicting with Ecto sandbox connections.
    children =
      if background_workers? do
        memory_background_children(multi_tenant?, true) ++
          if multi_tenant? do
            [
              Acs.Specs.Auditor,
              {Acs.Log.RetentionSweeper, []},
              Acs.Skills.Auditor | children
            ]
          else
            [
              Acs.Specs.FileWatcher,
              Acs.Specs.Auditor,
              {Acs.Log.RetentionSweeper, []},
              Acs.Skills.Auditor | children
            ]
          end ++ tools_watcher_children
      else
        children
      end

    # PubSub must start before any worker that subscribes to idle→active
    # wake broadcasts, so prepend it after the auditor children are folded in.
    children = [{Phoenix.PubSub, name: AcsWeb.PubSub} | children]

    opts = [strategy: :one_for_one, name: Acs.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Initial sync: populate SQLite index from YAML files on boot.
    # Only runs when background workers are enabled (not in test)
    # to avoid Ecto sandbox conflicts with background DB queries.
    if Application.get_env(:steward_acs, :start_background_workers, true) do
      Task.start(fn ->
        # Let the application become ready before a large corpus reaches Ollama.
        Process.sleep(Application.get_env(:steward_acs, :embedding_backfill_delay_ms, 5_000))

        unless Acs.Org.multi_tenant?() do
          {:ok, count, quarantined} = Acs.Memory.Indexer.sync_all()

          if quarantined != [] do
            Logger.warning(
              "[Application] Initial memory sync: #{count} indexed, #{length(quarantined)} quarantined"
            )
          else
            Logger.info("[Application] Initial memory sync: #{count} memories indexed")
          end
        end

        if Application.get_env(:steward_acs, :embedding_backfill_enabled, true) do
          case Acs.Memory.Embedding.ensure_embeddings() do
            {:ok, stats} ->
              Logger.info(
                "[Application] Embedding generation: #{stats.embedded} new, #{stats.existing} existing, #{stats.failed} failed out of #{stats.total}"
              )

            {:error, reason} ->
              Logger.warning("[Application] Embedding generation skipped: #{reason}")
          end
        else
          Logger.info(
            "[Application] Embedding backfill disabled; use a supervised job to rebuild stale embeddings"
          )
        end
      end)

      Task.start(fn ->
        Process.sleep(200)
        Acs.Skills.VectorSearch.create_table()

        case Acs.Skills.VectorSearch.ensure_embeddings() do
          {:ok, stats} ->
            Logger.info(
              "[Application] Skill embeddings: #{stats.embedded} new, #{stats.existing} existing, #{stats.failed} failed out of #{stats.total}"
            )

          {:error, reason} ->
            Logger.warning("[Application] Skill embeddings skipped: #{reason}")
        end
      end)

      Task.start(fn ->
        Process.sleep(300)
        Acs.Specs.VectorSearch.create_table()

        case Acs.Specs.VectorSearch.ensure_embeddings() do
          {:ok, stats} ->
            Logger.info(
              "[Application] Spec embeddings: #{stats.embedded} new, #{stats.existing} existing, #{stats.failed} failed out of #{stats.total_entries} entries / #{stats.total_chunks} chunks"
            )

          {:error, reason} ->
            Logger.warning("[Application] Spec embeddings skipped: #{reason}")
        end
      end)

      # Warmup ACS ETS cache from database after startup.
      Task.start(fn ->
        Process.sleep(100)
        Acs.Acs.Cache.warmup()
      end)
    end

    attach_mount_telemetry()

    {:ok, pid}
  end

  @doc false
  def log_analyzer_children do
    if Application.get_env(:steward_acs, :log_analyzer_enabled, true),
      do: [Acs.LogAnalyzer],
      else: []
  end

  defp attach_mount_telemetry do
    :telemetry.attach(
      "axiom-lv-mount",
      [:phoenix, :live_view, :mount],
      &handle_mount_telemetry/4,
      nil
    )
  end

  def handle_mount_telemetry(_event, measurements, metadata, _config) do
    Acs.IdleTracker.touch()

    duration_ms =
      measurements.duration
      |> System.convert_time_unit(:native, :microsecond)
      |> then(&(&1 / 1000))

    if axiom_enabled?() and Process.whereis(Acs.Observability.AxiomLogExporter) do
      Acs.Observability.AxiomLogExporter.enqueue(%{
        _time: DateTime.utc_now(),
        duration_ms: duration_ms,
        view: inspect(metadata.socket.view),
        org: metadata.session["current_org"],
        connected: metadata.socket.connected?
      })
    end
  end

  defp setup_observability do
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:steward_acs, :repo])
    OpentelemetryLoggerMetadata.setup()
  end

  defp axiom_enabled? do
    Application.get_env(:steward_acs, :axiom, [])[:enabled] == true
  end

  # Dedicated Axiom dataset for agent.tool / agent.feedback (default steward_meta_analytics).
  # Set AXIOM_AGENT_OPS_DATASET="" to disable the second exporter (events fall back to steward_logs).
  defp agent_ops_exporter_children do
    axiom = Application.get_env(:steward_acs, :axiom, [])

    dataset =
      case System.get_env("AXIOM_AGENT_OPS_DATASET") do
        nil -> "steward_meta_analytics"
        "" -> nil
        ds -> String.trim(ds)
      end

    if is_binary(dataset) and dataset != "" and axiom[:token] do
      [
        {Acs.Observability.AxiomLogExporter,
         [
           name: Acs.Observability.AgentOpsExporter,
           token: axiom[:token],
           dataset: dataset,
           domain: axiom[:domain] || "https://api.axiom.co",
           attach_backend: false
         ]}
      ]
    else
      []
    end
  end

  @doc false
  def memory_background_children(_multi_tenant?, false), do: []
  def memory_background_children(true, true), do: [Acs.Memory.Auditor]

  def memory_background_children(false, true) do
    [Acs.Memory.Auditor, Acs.Memory.FileWatcher, Acs.Memory.VaultSweeper]
  end

  defp vault_configured? do
    case Application.get_env(:steward_acs, :obsidian_vault_path) do
      path when is_binary(path) -> path != ""
      _ -> false
    end
  end
end

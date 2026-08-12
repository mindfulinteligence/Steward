import Config

cors_origins =
  case System.get_env("CORS_ORIGINS") do
    nil -> ["http://localhost:4001"]
    "" -> ["http://localhost:4001"]
    origins -> origins |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

config :cors_plug,
  origin: cors_origins,
  max_age: 86_400,
  methods: ["GET", "POST", "PATCH", "OPTIONS"],
  headers: [
    "content-type",
    "authorization",
    "x-requested-with",
    "x-mcp-session-id",
    "x-log-ingest-key",
    "x-api-key"
  ],
  expose: ["x-mcp-session-id"]

config :steward_acs,
  namespace: Acs,
  ecto_repos: [Acs.Repo],
  generators: [timestamp_type: :utc_datetime]

config :steward_acs, AcsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AcsWeb.ErrorHTML, json: AcsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AcsWeb.PubSub,
  code_reloader: false

config :phoenix, :json_library, Jason

# Mail — Local by default; runtime.exs switches to Resend when RESEND_API_KEY is set.
config :steward_acs, Acs.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false
config :steward_acs, :email_delivery_enabled, false

config :steward_acs, :session_validity_in_days, 7

config :steward_acs,
  account_host: "localhost",
  self_service_orgs_enabled: false,
  oidc_browser_enabled: false,
  oidc_strategy: Assent.Strategy.OIDC,
  basic_auth: [username: "admin", password: "admin"]

# Observability is opt-in at runtime. This prevents the OpenTelemetry SDK from
# falling back to its localhost collector when Axiom is not configured.
config :steward_acs, :axiom, enabled: false
config :opentelemetry, traces_exporter: :none

config :logger, :console,
  metadata: [
    :agent_id,
    :task_id,
    :file_path,
    :locked_by,
    :axiom_exporter_internal,
    :org,
    :subdomain,
    :action,
    :status,
    :role,
    :request_id,
    :provider,
    :model,
    :base_url,
    :latency_ms,
    :error_type,
    :component,
    :live_view,
    :page,
    :service,
    :count,
    :llm_event,
    :tokens_in,
    :tokens_out,
    :tokens_total,
    :call_type,
    :subject_id,
    :audience,
    :prompt_chars,
    :recommendation,
    :quality_score,
    :error,
    :next_provider,
    :providers,
    :cache_name,
    :cache_result,
    :cache_type
  ]

# Configure esbuild
config :esbuild,
  version: "0.21.5",
  steward_acs: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

import_config "#{config_env()}.exs"

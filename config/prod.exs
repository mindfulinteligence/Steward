import Config

repo_adapter =
  case System.get_env("REPO_ADAPTER", "postgres") do
    "sqlite" -> Ecto.Adapters.SQLite3
    _ -> Ecto.Adapters.Postgres
  end

config :steward_acs, :repo_adapter, repo_adapter

# Individual PG settings are fallbacks when DATABASE_URL is not set at runtime.
if repo_adapter == Ecto.Adapters.Postgres do
  pgpassword = System.get_env("PGPASSWORD", "postgres")

  # DATABASE_URL overrides these individual settings at runtime; only enforce
  # when falling back to PGPASSWORD.
  if config_env() == :prod and is_nil(System.get_env("DATABASE_URL")) and pgpassword == "postgres" do
    raise "PGPASSWORD must not be the default 'postgres' in production"
  end

  config :steward_acs, Acs.Repo,
    username: System.get_env("PGUSER", "postgres"),
    password: pgpassword,
    hostname: System.get_env("PGHOST", "localhost"),
    port: String.to_integer(System.get_env("PGPORT", "5432")),
    database: System.get_env("PGDATABASE", "acs_prod"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    idle_interval: String.to_integer(System.get_env("DB_IDLE_INTERVAL_MS", "86400000")),
    ssl: System.get_env("PGSSL", "false") == "true"
end

config :steward_acs, AcsWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: String.to_integer(System.get_env("PORT", "4001"))],
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json",
  force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true]

config :steward_acs, :mcp_auth_local_fallback, false
config :steward_acs, :secure_session_cookie, true
config :steward_acs, :hsts, true
config :steward_acs, :log_ingest_key, System.get_env("LOG_INGEST_KEY", "")

config :steward_acs, Acs.MCP.Server,
  enabled: true,
  transport: :http

config :logger, level: :info

# Tenant-writable tools are discovered from each canonical vault root.
# These paths are read-only shared/plugin sources available to every tenant.
config :steward_acs, Acs.MCP.ToolLoader,
  shared_tools_paths:
    [
      System.get_env("EXTERNAL_TOOLS_PATH"),
      System.get_env("ACS_TOOLS_PATH", "/app/acs/acstools/")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == "")),
  trusted_handler_modules:
    System.get_env("TRUSTED_MCP_HANDLER_MODULES", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

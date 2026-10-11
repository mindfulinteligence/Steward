import Config

config :steward_acs, :repo_adapter, Ecto.Adapters.SQLite3
config :steward_acs, :account_host, "localhost"
config :steward_acs, :oidc_browser_enabled, false

# SQLite test database
config :steward_acs, Acs.Repo,
  database: Path.expand("../tmp/acs_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  busy_timeout: 10_000,
  default_transaction_mode: :immediate,
  show_sensitive_data_on_connection_error: true

# Print only warnings and errors during test
config :logger, level: :warning

# No MCP server during tests — transport kept for compile_env consistency
config :steward_acs, Acs.MCP.Server, enabled: false, transport: :http
config :steward_acs, :start_background_workers, false
config :steward_acs, :persist_logs_to_db, false
config :steward_acs, :mcp_auth_local_fallback, false
config :steward_acs, :memory_intake_llm, false
config :steward_acs, :skill_intake_llm, false
config :steward_acs, :log_ingest_key, "test-log-ingest-key"

# Isolate test memory files from _build artifact copies under priv/acs_memory/
config :steward_acs, :obsidian_vault_path, Path.expand("../tmp/test_acs_memory", __DIR__)

config :steward_acs, AcsWeb.Endpoint,
  secret_key_base: "test_secret_key_base_for_exunit_only_not_for_production_use_1234567890",
  live_view: [signing_salt: "test_signing_salt"]

config :steward_acs, Acs.Mailer, adapter: Swoosh.Adapters.Test
config :steward_acs, :email_delivery_enabled, false
config :steward_acs, :resend_from_email, {"Steward ACS", "noreply@example.test"}

# Fixtures insert orgs directly (no Orgs.create → no invalidation); a cached
# miss from an earlier test would hide them.
config :steward_acs, :org_subdomain_cache, false

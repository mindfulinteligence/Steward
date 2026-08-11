import Config

# Load .env before reading runtime configuration in mix phx.server.
# Dotenvy stores vars in its process dictionary by default; put unset keys into System
# so existing System.get_env/2 config reads work.
env_path = System.get_env("ENV_PATH") || Path.expand("../.env", __DIR__)

if File.exists?(env_path) do
  env_path
  |> List.wrap()
  |> Dotenvy.source!()
  |> Enum.each(fn {key, value} ->
    if System.get_env(key) in [nil, ""], do: System.put_env(key, value)
  end)
end

axiom_token = System.get_env("AXIOM_LOGS", "") |> String.trim()

if config_env() == :prod and axiom_token != "" do
  axiom_domain =
    System.get_env("AXIOM_DOMAIN", "https://us-east-1.aws.edge.axiom.co")
    |> String.trim()
    |> String.trim_trailing("/")

  domain_uri = URI.parse(axiom_domain)

  valid_axiom_origin? =
    domain_uri.scheme == "https" and domain_uri.host not in [nil, ""] and
      domain_uri.path in [nil, "", "/"] and is_nil(domain_uri.userinfo) and
      is_nil(domain_uri.query) and is_nil(domain_uri.fragment) and
      (is_nil(domain_uri.port) or domain_uri.port in 1..65_535)

  unless valid_axiom_origin? do
    raise "AXIOM_DOMAIN must be an HTTPS origin, for example https://us-east-1.aws.edge.axiom.co"
  end

  axiom_dataset =
    case System.get_env("AXIOM_DATASET", "") |> String.trim() do
      "" -> "steward_logs"
      dataset -> dataset
    end

  config :steward_acs, :axiom,
    enabled: true,
    token: axiom_token,
    dataset: axiom_dataset,
    domain: axiom_domain

  config :opentelemetry,
    resource: %{service: %{name: "steward_acs"}},
    span_processor:
      {Acs.Observability.RedactingBatchSpanProcessor, %{exporter: {:opentelemetry_exporter, %{}}}},
    traces_exporter: :otlp

  config :opentelemetry_exporter,
    otlp_traces_protocol: :http_protobuf,
    otlp_traces_endpoint: "#{axiom_domain}/v1/traces",
    otlp_traces_headers: [
      {"authorization", "Bearer #{axiom_token}"},
      {"x-axiom-dataset", axiom_dataset}
    ]
else
  config :steward_acs, :axiom, enabled: false
  config :opentelemetry, traces_exporter: :none
end

secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    if config_env() == :prod do
      raise "SECRET_KEY_BASE environment variable is required in production. " <>
              "Generate one with: mix phx.gen.secret"
    else
      :crypto.strong_rand_bytes(64) |> Base.encode64()
    end

signing_salt =
  System.get_env("SESSION_SIGNING_SALT") ||
    :crypto.hash(:sha256, secret_key_base)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)

config :steward_acs, AcsWeb.Endpoint,
  secret_key_base: secret_key_base,
  live_view: [signing_salt: signing_salt]

config :steward_acs,
       :auditor_interval,
       System.get_env("AUDITOR_INTERVAL", "30000") |> String.to_integer()

config :steward_acs,
       :auditor_max_concurrency,
       System.get_env("AUDITOR_MAX_CONCURRENCY", "20") |> String.to_integer()

config :steward_acs,
       :session_validity_in_days,
       System.get_env("SESSION_VALIDITY_DAYS", "7") |> String.to_integer()

# DATABASE_PATH wins for local/SQLite. Never apply Neon URL alongside a path.
db_path = System.get_env("DATABASE_PATH")
db_url = System.get_env("DATABASE_URL")

if db_path in [nil, ""] and db_url not in [nil, ""] do
  use_ssl? =
    case System.get_env("PGSSL") do
      "true" ->
        true

      "false" ->
        false

      _ ->
        String.contains?(db_url, "neon.tech") or
          String.contains?(db_url, "sslmode=require") or
          String.contains?(db_url, "sslmode=verify-full")
    end

  repo_opts = [
    url: db_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  ]

  repo_opts =
    if use_ssl? do
      ssl_opts =
        case :public_key.cacerts_get() do
          cacerts when is_list(cacerts) and cacerts != [] ->
            [
              verify: :verify_peer,
              cacerts: cacerts,
              customize_hostname_check: [
                match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
              ]
            ]

          _ ->
            # ponytail: no CA store in runtime image — connect still encrypted
            [verify: :verify_none]
        end

      Keyword.merge(repo_opts, ssl: true, ssl_opts: ssl_opts)
    else
      repo_opts
    end

  config :steward_acs, Acs.Repo, repo_opts
end

if config_env() == :prod do
  db_path = System.get_env("DATABASE_PATH")
  db_url = System.get_env("DATABASE_URL")

  cond do
    db_path not in [nil, ""] ->
      :ok

    db_url not in [nil, ""] ->
      if String.contains?(db_url, "://postgres:postgres@") do
        raise "DATABASE_URL must not use the default postgres password in production"
      end

    System.get_env("PGPASSWORD", "postgres") == "postgres" ->
      raise "PGPASSWORD must not be the default 'postgres' in production"

    true ->
      raise "DATABASE_URL or DATABASE_PATH must be set in production"
  end

  if System.get_env("MCP_API_KEY", "") == "" do
    raise "MCP_API_KEY environment variable is required in production"
  end
end

# Empty DATABASE_PATH (postgres override) must not force SQLite.
# Never in :test — a sourced .env would point mix test at the live dev database.
runtime_db_path =
  if config_env() == :test, do: nil, else: System.get_env("DATABASE_PATH")

if runtime_db_path not in [nil, ""] do
  config :steward_acs, :repo_adapter, Ecto.Adapters.SQLite3

  config :steward_acs, Acs.Repo,
    database: runtime_db_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))
end

if System.get_env("BRIDGE_ALLOWED_HOSTS") do
  config :steward_acs,
         :bridge_allowed_hosts,
         System.get_env("BRIDGE_ALLOWED_HOSTS")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
end

if mcp_api_key = System.get_env("MCP_API_KEY") do
  config :steward_acs, :mcp_api_key, mcp_api_key
end

if service_api_key = System.get_env("SERVICE_API_KEY") do
  config :steward_acs, :service_api_key, service_api_key
end

if log_ingest_key = System.get_env("LOG_INGEST_KEY") do
  config :steward_acs, :log_ingest_key, log_ingest_key
end

if System.get_env("MCP_AUTH_LOCAL_FALLBACK") do
  config :steward_acs,
         :mcp_auth_local_fallback,
         System.get_env("MCP_AUTH_LOCAL_FALLBACK") == "true"
end

if System.get_env("MCP_QUERY_KEY_AUTH") do
  config :steward_acs,
         :mcp_query_key_auth,
         System.get_env("MCP_QUERY_KEY_AUTH") == "true"
end

oauth_bearer_enabled = System.get_env("OAUTH_BEARER_ENABLED") == "true"
multi_tenant? = System.get_env("MULTI_TENANT", "false") == "true"

# Fail loud: OAuth in single-tenant half-works (Cursor re-prompts every run).
Acs.MCP.OAuth.Config.assert_runtime_allowed!(oauth_bearer_enabled, multi_tenant?)

if oauth_bearer_enabled do
  config :steward_acs,
         :oauth_bearer_enabled,
         true

  config :steward_acs, :auth_strategies, [
    Acs.MCP.Plugs.Strategies.Developer,
    Acs.MCP.Plugs.Strategies.OAuthBearer,
    Acs.MCP.Plugs.Strategies.Default
  ]
end

if auth0_domain = System.get_env("AUTH0_DOMAIN") do
  config :steward_acs, :auth0_domain, auth0_domain
end

if fixed_dcr = System.get_env("OAUTH_FIXED_DCR_CLIENT_ID") do
  config :steward_acs, :oauth_fixed_dcr_client_id, fixed_dcr
end

if auth0_audience = System.get_env("AUTH0_AUDIENCE") do
  config :steward_acs, :auth0_audience, auth0_audience
end

if auth0_issuer = System.get_env("AUTH0_ISSUER") do
  config :steward_acs, :auth0_issuer, auth0_issuer
end

if mgmt_id = System.get_env("AUTH0_MGMT_CLIENT_ID") do
  if mgmt_id != "" do
    config :steward_acs, :auth0_mgmt_client_id, mgmt_id
  end
end

if mgmt_secret = System.get_env("AUTH0_MGMT_CLIENT_SECRET") do
  if mgmt_secret != "" do
    config :steward_acs, :auth0_mgmt_client_secret, mgmt_secret
  end
end

if connection = System.get_env("AUTH0_CONNECTION") do
  if connection != "" do
    config :steward_acs, :auth0_connection, connection
  end
end

if mcp_public_url = System.get_env("MCP_PUBLIC_URL") do
  config :steward_acs, :mcp_public_url, mcp_public_url
end

if mcp_resource_url = System.get_env("MCP_RESOURCE_URL") do
  config :steward_acs, :mcp_resource_url, mcp_resource_url
end

config :steward_acs, :nim_api_key, System.get_env("NIM_API_KEY", "")
config :steward_acs, :mimo_api_key, System.get_env("MIMO_API_KEY", "")
config :steward_acs, :minimax_api_key, System.get_env("MINIMAX_API_KEY", "")
config :steward_acs, :openai_api_key, System.get_env("OPENAI_API_KEY", "")
config :steward_acs, :openai_base_url, System.get_env("OPENAI_BASE_URL", "")
config :steward_acs, :openai_model, System.get_env("OPENAI_MODEL", "")

config :steward_acs,
       :enabled_llm_providers,
       System.get_env("ENABLED_LLM_PROVIDERS", "")
       |> String.split(",", trim: true)
       |> Enum.map(&String.trim/1)

# ─── Memory Auditor Pre-filter Configuration ───────────────────────────
# Lists of comma-separated patterns for auto-reject pre-filter rules.
if prefixes = System.get_env("AUDITOR_REJECT_TITLE_PREFIXES") do
  config :steward_acs,
         :auditor_reject_title_prefixes,
         String.split(prefixes, ",", trim: true) |> Enum.map(&String.trim/1)
end

if exact = System.get_env("AUDITOR_REJECT_TITLE_EXACT") do
  config :steward_acs,
         :auditor_reject_title_exact,
         String.split(exact, ",", trim: true) |> Enum.map(&String.trim/1)
end

if scopes = System.get_env("AUDITOR_REJECT_SCOPE_PREFIXES") do
  config :steward_acs,
         :auditor_reject_scope_prefixes,
         String.split(scopes, ",", trim: true) |> Enum.map(&String.trim/1)
end

if id_prefixes = System.get_env("AUDITOR_REJECT_ID_PREFIXES") do
  config :steward_acs,
         :auditor_reject_id_prefixes,
         String.split(id_prefixes, ",", trim: true) |> Enum.map(&String.trim/1)
end

if id_contains = System.get_env("AUDITOR_REJECT_ID_CONTAINS") do
  config :steward_acs,
         :auditor_reject_id_contains,
         String.split(id_contains, ",", trim: true) |> Enum.map(&String.trim/1)
end

if min_len = System.get_env("AUDITOR_MIN_CONTENT_LENGTH") do
  config :steward_acs, :auditor_min_content_length, String.to_integer(min_len)
end

if low_len = System.get_env("AUDITOR_LOW_CONTENT_LENGTH") do
  config :steward_acs, :auditor_low_content_length, String.to_integer(low_len)
end

if threshold = System.get_env("AUDITOR_FUZZY_THRESHOLD") do
  config :steward_acs, :auditor_fuzzy_threshold, String.to_float(threshold)
end

if System.get_env("AUDITOR_REJECT_EMPTY_SCOPE") do
  config :steward_acs,
         :auditor_reject_empty_scope,
         System.get_env("AUDITOR_REJECT_EMPTY_SCOPE") == "true"
end

if System.get_env("AUDITOR_REJECT_TITLE_EQUALS_CONTENT") do
  config :steward_acs,
         :auditor_reject_title_equals_content,
         System.get_env("AUDITOR_REJECT_TITLE_EQUALS_CONTENT") == "true"
end

config :steward_acs, Acs.Memory.Embedding,
  ollama_url: System.get_env("OLLAMA_URL", "http://localhost:11434")

config :steward_acs,
       :org_name,
       System.get_env("ACS_ORG_NAME") || System.get_env("ACS_CLUSTER_NAME", "default")

multi_tenant? = System.get_env("MULTI_TENANT", "false") == "true"
memory_store = System.get_env("MEMORY_STORE", if(multi_tenant?, do: "database", else: "yaml"))

if multi_tenant? and memory_store != "database" do
  raise "MULTI_TENANT=true requires MEMORY_STORE=database; filesystem memory stores are not supported"
end

config :steward_acs, :multi_tenant, multi_tenant?

if orgs_file = System.get_env("ORGS_FILE") do
  config :steward_acs, :orgs_file, orgs_file
end

if base_domain = System.get_env("BASE_DOMAIN") do
  config :steward_acs, :base_domain, base_domain
end

config :steward_acs, :project_name, System.get_env("ACS_PROJECT_NAME", "")

config :steward_acs,
       :developer_name,
       System.get_env("ACS_DEVELOPER_NAME", "unknown")

config :steward_acs, :memory_store, memory_store

if obsidian_path = System.get_env("OBSIDIAN_VAULT_PATH") do
  config :steward_acs, :obsidian_vault_path, obsidian_path
end

if config_env() == :prod do
  host =
    case System.get_env("PHX_HOST") do
      nil -> System.get_env("DOMAIN")
      "" -> System.get_env("DOMAIN")
      value -> value
    end

  if is_nil(host) or host == "" do
    raise "PHX_HOST or DOMAIN environment variable is required in production"
  end

  check_origin =
    if System.get_env("MULTI_TENANT", "false") == "true" do
      base =
        System.get_env("BASE_DOMAIN") ||
          host |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

      [
        "https://#{host}",
        "http://#{host}",
        "//*.#{base}",
        "//#{base}"
      ]
    else
      ["https://#{host}", "http://#{host}"]
    end

  config :steward_acs, AcsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: check_origin
end

endpoint_url = Application.get_env(:steward_acs, AcsWeb.Endpoint, []) |> Keyword.get(:url, [])
endpoint_host = Keyword.get(endpoint_url, :host, "localhost")

oidc_issuer =
  case System.get_env("AUTH0_ISSUER") do
    issuer when is_binary(issuer) and issuer != "" ->
      String.trim_trailing(issuer, "/") <> "/"

    _ ->
      case System.get_env("AUTH0_DOMAIN") do
        domain when is_binary(domain) and domain != "" ->
          "https://" <> String.trim_trailing(domain, "/") <> "/"

        _ ->
          nil
      end
  end

config :steward_acs,
  account_host: System.get_env("ACCOUNT_HOST") || endpoint_host,
  self_service_orgs_enabled: System.get_env("SELF_SERVICE_ORGS_ENABLED", "false") == "true",
  oidc_browser_enabled: System.get_env("OIDC_BROWSER_ENABLED", "false") == "true",
  oidc_issuer: oidc_issuer,
  oidc_client_id: System.get_env("AUTH0_WEB_CLIENT_ID"),
  oidc_client_secret: System.get_env("AUTH0_WEB_CLIENT_SECRET"),
  oidc_redirect_uri: System.get_env("AUTH0_WEB_REDIRECT_URI")

if origins = System.get_env("CORS_ORIGINS") do
  config :cors_plug,
    origin:
      origins
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
end

# Optional invitation email via Resend. Both key and from address required;
# omit either to keep copy-link-only invites (email_delivery_enabled stays false).
resend_api_key = System.get_env("RESEND_API_KEY", "") |> String.trim()
resend_from_raw = System.get_env("RESEND_FROM_EMAIL", "") |> String.trim()

resend_from =
  case Regex.run(~r/\A\s*(.*?)\s*<([^>]+)>\s*\z/, resend_from_raw) do
    [_, name, email] -> {String.trim(name), String.trim(email)}
    _ when resend_from_raw != "" -> resend_from_raw
    _ -> nil
  end

if resend_api_key != "" and not is_nil(resend_from) do
  config :steward_acs, Acs.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: resend_api_key

  config :swoosh, :api_client, Swoosh.ApiClient.Req
  config :steward_acs, :email_delivery_enabled, true
  config :steward_acs, :resend_from_email, resend_from
end

defmodule Acs.MCP.ClientSession do
  @moduledoc """
  Per-MCP-session metadata (audience, clientInfo) captured at `initialize`.

  Keys may be:
  - binary session_id (HTTP/SSE)
  - `{:agent, agent_identity}` fallback when session ids are not sticky

  Request-scoped session id is bound via `bind/2` so Protocol can read it
  without changing every call site arity.
  """

  use GenServer

  @process_key {__MODULE__, :session_id}
  @session_ttl_ms 3_600_000
  @cleanup_interval_ms 60_000
  @max_sessions 10_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Bind session_id for the duration of fun/0 (request-scoped)."
  def bind(session_id, fun) when is_function(fun, 0) do
    previous = Process.get(@process_key)
    Process.put(@process_key, session_id)

    try do
      fun.()
    after
      if previous, do: Process.put(@process_key, previous), else: Process.delete(@process_key)
    end
  end

  def current_id, do: Process.get(@process_key)

  def put(nil, _attrs), do: :ok

  def put(key, attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:put, key, attrs})
  end

  def fetch(nil), do: {:error, :not_found}

  def fetch(key) do
    GenServer.call(__MODULE__, {:fetch, key})
  end

  @doc """
  Get or assign a pool-based agent name for the current session.
  Returns the cached name if already assigned, otherwise gets a new
  name from the round-robin pool and stores it in session data.
  """
  def get_or_assign_agent_name do
    get_or_assign_agent_name(current_id())
  end

  def get_or_assign_agent_name(key) when is_binary(key) do
    pool_agent_name(key)
  end

  def get_or_assign_agent_name(_), do: nil

  @doc """
  Mark a session as sticky so it keeps its own per-session agent name
  instead of resolving to the identity key. Sticky sessions are stable
  connections (SSE or an echoed `x-mcp-session-id`).
  """
  def set_sticky(key, sticky?) when is_binary(key) and is_boolean(sticky?) do
    merge_put(key, %{sticky: sticky?})
    :ok
  end

  def set_sticky(_key, _sticky?), do: :ok

  @doc """
  Get or assign a pool-based agent name qualified with the human user's
  name (e.g. `nahar_alice`).

  The name stays stable for the caller so it keeps validating against the
  authenticated identity across requests:

    * Sticky sessions (a stable bound session id) keep their own per-session
      `user_pool` name — a single human can run several coding agents at a
      time, each with its own name.
    * Non-sticky HTTP sessions (a fresh session id per request) fall back to
      the identity key `{:agent, prefix}`. The first assigned name is
      mirrored there first-writer-wins, so every request of that human
      resolves to the same name.
    * Hits refresh the session TTL so long-running agents don't re-rotate
      after the 1h expiry.
  """
  def get_or_assign_qualified_agent_name(prefix) when is_binary(prefix) and prefix != "" do
    session_key = current_id()
    identity_key = agent_key(prefix)

    case qualified_agent_name(session_key) do
      name when is_binary(name) and name != "" ->
        touch(session_key)
        name

      _ ->
        if sticky_session?(session_key) do
          get_or_assign_qualified_agent_name(prefix, session_key)
        else
          case qualified_agent_name(identity_key) do
            name when is_binary(name) and name != "" ->
              touch(identity_key)
              name

            _ ->
              name = get_or_assign_qualified_agent_name(prefix, session_key || identity_key)
              mirror_identity_name(identity_key, name)
              name
          end
        end
    end
  end

  def get_or_assign_qualified_agent_name(prefix, key)
      when (is_binary(key) or is_tuple(key)) and not is_nil(key) do
    with {:ok, data} <- fetch(key),
         name when is_binary(name) and name != "" <- Map.get(data, :qualified_agent_name) do
      put(key, Map.put(data, :qualified_agent_name, name))
      name
    else
      _ ->
        pool_name = pool_agent_name(key)
        qualified = "#{normalize_user_prefix(prefix)}_#{pool_name}"

        with {:ok, data} <- fetch(key) do
          put(key, Map.put(data, :qualified_agent_name, qualified))
        else
          _ -> put(key, %{qualified_agent_name: qualified})
        end

        qualified
    end
  end

  def get_or_assign_qualified_agent_name(_prefix, _key), do: nil

  defp qualified_agent_name(nil), do: nil

  defp qualified_agent_name(key) do
    with {:ok, data} <- fetch(key),
         name when is_binary(name) and name != "" <- Map.get(data, :qualified_agent_name) do
      name
    else
      _ -> nil
    end
  end

  defp sticky_session?(nil), do: false

  defp sticky_session?(key) do
    case fetch(key) do
      {:ok, %{sticky: true}} -> true
      _ -> false
    end
  end

  defp touch(nil), do: :ok

  defp touch(key) do
    with {:ok, data} <- fetch(key) do
      put(key, data)
    else
      _ -> :ok
    end
  end

  # Merge attrs into an existing session instead of replacing it wholesale, so
  # metadata written by different stages (sticky flag, qualified agent name,
  # audience, working repo) all survive across requests and initialize.
  defp merge_put(key, attrs) when (is_binary(key) or is_tuple(key)) and is_map(attrs) do
    case fetch(key) do
      {:ok, data} when is_map(data) -> put(key, Map.merge(data, attrs))
      _ -> put(key, attrs)
    end
  end

  defp merge_put(_key, _attrs), do: :ok

  defp mirror_identity_name(nil, _name), do: :ok

  defp mirror_identity_name(identity_key, name) when is_binary(name) and name != "" do
    if is_nil(qualified_agent_name(identity_key)) do
      with {:ok, data} <- fetch(identity_key) do
        put(identity_key, Map.put(data, :qualified_agent_name, name))
      else
        _ -> put(identity_key, %{qualified_agent_name: name})
      end
    end

    :ok
  end

  defp pool_agent_name(key) do
    with {:ok, data} <- fetch(key),
         name when is_binary(name) and name != "" <- Map.get(data, :agent_name) do
      name
    else
      _ ->
        pool_name = Acs.Acs.Cache.get_and_increment_agent_index()

        with {:ok, data} <- fetch(key) do
          put(key, Map.put(data, :agent_name, pool_name))
        else
          _ -> put(key, %{agent_name: pool_name})
        end

        pool_name
    end
  end

  defp normalize_user_prefix(prefix) do
    case prefix
         |> String.trim()
         |> String.downcase()
         |> String.replace(~r/[^a-z0-9]+/, "_")
         |> String.trim("_") do
      "" -> "user"
      normalized -> normalized
    end
  end

  @doc """
  Resolve audience for the current request.

  Prefers the bound session id, then `{:agent, agent_identity}`, else default.
  """
  def resolve_audience(agent_identity \\ nil) do
    with {:error, _} <- fetch_audience(current_id()),
         {:error, _} <- fetch_audience(agent_key(agent_identity)) do
      Acs.MCP.Audience.default_audience()
    else
      {:ok, audience} -> audience
    end
  end

  @doc """
  Seed audience from the SSE URL before `initialize` (path or `?audience=`).

  URL-forced audience wins over later `clientInfo` heuristics so Claude.ai /
  ChatGPT connectors get the curated chat tool surface when pointed at
  `/mcp/chat/sse` or `/mcp/sse?audience=chat`.
  """
  def seed_url_audience(session_id, audience) when audience in [:chat, :coding] do
    seed_mcp_connect(session_id, nil, audience)
  end

  def seed_url_audience(_session_id, _), do: :ok

  @doc """
  Record MCP connect path + audience on the session (before `initialize`).

  `endpoint_path` is e.g. `/mcp/coding/sse`, `/mcp/chat/sse`, `/mcp/v1/messages`.
  """
  def seed_mcp_connect(session_id, endpoint_path, audience)
      when audience in [:chat, :coding] do
    attrs = %{audience: audience, audience_source: :url}

    attrs =
      case Acs.MCP.MemoryProvenance.normalize_endpoint(endpoint_path) do
        nil -> attrs
        endpoint -> Map.put(attrs, :mcp_endpoint, endpoint)
      end

    merge_put(session_id, attrs)
  end

  def seed_mcp_connect(_session_id, _endpoint_path, _), do: :ok

  @doc "MCP endpoint path for the current session (e.g. `/mcp/chat/sse`)."
  def resolve_mcp_endpoint(agent_identity \\ nil) do
    with {:error, _} <- fetch_mcp_endpoint(current_id()),
         {:error, _} <- fetch_mcp_endpoint(agent_key(agent_identity)) do
      nil
    else
      {:ok, endpoint} -> endpoint
    end
  end

  @doc "MCP clientInfo.name for the current session (e.g. Claude vs GPT)."
  def resolve_client_name(agent_identity \\ nil) do
    resolve_session_field(agent_identity, :client_name)
  end

  @doc "MCP clientInfo.version for the current session."
  def resolve_client_version(agent_identity \\ nil) do
    resolve_session_field(agent_identity, :client_version)
  end

  @doc "How audience was chosen (`url` | `client_info`)."
  def resolve_audience_source(agent_identity \\ nil) do
    resolve_session_field(agent_identity, :audience_source)
  end

  @doc "Bind the repository and workspace established by the first file lock."
  def set_working_repo(repo, workspace_id \\ nil, agent_identity \\ nil) do
    attrs = %{working_repo: Acs.Repos.normalize(repo), workspace_id: workspace_id}
    merge_put(current_id(), attrs)
    merge_put(agent_key(agent_identity), attrs)
    :ok
  end

  def resolve_working_repo(agent_identity \\ nil),
    do: resolve_session_field(agent_identity, :working_repo)

  def resolve_workspace_id(agent_identity \\ nil),
    do: resolve_session_field(agent_identity, :workspace_id)

  @doc "Bind the most recent confirmed work scope for contextual retrieval."
  def set_working_scope(scope_path, agent_identity \\ nil) do
    attrs = %{working_scope: scope_path}
    merge_put(current_id(), attrs)
    merge_put(agent_key(agent_identity), attrs)
    :ok
  end

  def resolve_working_scope(agent_identity \\ nil),
    do: resolve_session_field(agent_identity, :working_scope)

  def remember_initialize(params, agent_identity) when is_map(params) do
    client_info = params["clientInfo"] || params[:clientInfo] || %{}
    client_name = client_info["name"] || client_info[:name]
    client_version = client_info["version"] || client_info[:version]

    {audience, source} =
      case url_forced_audience(current_id()) do
        {:ok, forced} -> {forced, :url}
        :error -> {Acs.MCP.Audience.from_initialize_params(params), :client_info}
      end

    attrs = %{
      audience: audience,
      audience_source: source,
      client_name: client_name,
      client_version: client_version
    }

    attrs =
      case fetch_mcp_endpoint(current_id()) do
        {:ok, endpoint} -> Map.put(attrs, :mcp_endpoint, endpoint)
        _ -> attrs
      end

    merge_put(current_id(), attrs)
    merge_put(agent_key(agent_identity), attrs)
    audience
  end

  defp url_forced_audience(nil), do: :error

  defp url_forced_audience(key) do
    case fetch(key) do
      {:ok, %{audience_source: :url, audience: audience}} when audience in [:chat, :coding] ->
        {:ok, audience}

      _ ->
        :error
    end
  end

  defp fetch_audience(nil), do: {:error, :not_found}

  defp fetch_audience(key) do
    case fetch(key) do
      {:ok, %{audience: audience}} when audience in [:coding, :chat] -> {:ok, audience}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_mcp_endpoint(nil), do: {:error, :not_found}

  defp fetch_mcp_endpoint(key) do
    case fetch(key) do
      {:ok, %{mcp_endpoint: endpoint}} when is_binary(endpoint) and endpoint != "" ->
        {:ok, endpoint}

      _ ->
        {:error, :not_found}
    end
  end

  defp resolve_session_field(agent_identity, field) when is_atom(field) do
    with {:error, _} <- fetch_session_field(current_id(), field),
         {:error, _} <- fetch_session_field(agent_key(agent_identity), field) do
      nil
    else
      {:ok, value} -> value
    end
  end

  defp fetch_session_field(nil, _field), do: {:error, :not_found}

  defp fetch_session_field(key, field) do
    case fetch(key) do
      {:ok, data} when is_map(data) ->
        case Map.get(data, field) do
          value when is_binary(value) and value != "" -> {:ok, value}
          value when is_atom(value) and not is_nil(value) -> {:ok, value}
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp agent_key(nil), do: nil
  defp agent_key(""), do: nil
  defp agent_key(id) when is_binary(id), do: {:agent, id}
  defp agent_key(_), do: nil

  @impl true
  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:put, key, attrs}, _from, state) do
    state = if map_size(state) >= @max_sessions, do: remove_expired(state), else: state

    if map_size(state) >= @max_sessions and not Map.has_key?(state, key) do
      {:reply, {:error, :session_limit_reached}, state}
    else
      stored = Map.merge(attrs, %{inserted_at: System.monotonic_time(:millisecond)})
      {:reply, :ok, Map.put(state, key, stored)}
    end
  end

  def handle_call({:fetch, key}, _from, state) do
    case Map.fetch(state, key) do
      {:ok, session} ->
        if expired?(session) do
          {:reply, {:error, :expired}, Map.delete(state, key)}
        else
          {:reply, {:ok, session}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    schedule_cleanup()
    {:noreply, remove_expired(state)}
  end

  defp remove_expired(state) do
    Map.reject(state, fn {_key, session} -> expired?(session) end)
  end

  defp expired?(session) do
    System.monotonic_time(:millisecond) - session.inserted_at > @session_ttl_ms
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end

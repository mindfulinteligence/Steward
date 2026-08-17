defmodule Acs.MCP.HTTPServer do
  @moduledoc """
  MCP Server implementation using HTTP/SSE transport.
  Handles JSON-RPC requests over HTTP and Server-Sent Events for notifications.

  ## Authentication Context

  The `MCPAuth` plug injects `agent_role`, `agent_org_id`, and `agent_permissions`
  into conn.assigns. These are forwarded to `Protocol.handle_message/4` for
  RBAC enforcement:
  - `agent_role` — role-based access control (tool's `roles` field)
  - `agent_permissions` — permission-based RBAC (tool's `permissions` field)
  """
  use Plug.Router

  alias Acs.MCP.LogStore
  alias Acs.MCP.Protocol

  require Logger

  @max_log_batch 500
  @max_body_size 2_000_000

  plug(:match)
  plug(Acs.MCP.Plugs.RateLimit)
  plug(Acs.MCP.Plugs.MCPAuth)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: @max_body_size)
  plug(:dispatch)

  # MCP SSE — coding (default) and chat surfaces.
  # Chat: /mcp/chat/sse or /mcp/sse?audience=chat — curated tools matching chat_system_prompt.
  # Coding: /mcp/sse (default), /mcp/coding/sse, or ?audience=coding
  get "/mcp/sse" do
    open_sse(conn)
  end

  get "/mcp/chat/sse" do
    open_sse(conn)
  end

  get "/mcp/coding/sse" do
    open_sse(conn)
  end

  # Streamable HTTP (Claude connectors POST JSON-RPC to the MCP URL itself).
  # Legacy HTTP+SSE still POSTs to /mcp/messages?session_id=… after the endpoint event.
  post "/mcp/sse" do
    handle_streamable_post(conn)
  end

  post "/mcp/chat/sse" do
    handle_streamable_post(conn)
  end

  post "/mcp/coding/sse" do
    handle_streamable_post(conn)
  end

  # MCP Streamable HTTP messages endpoint — receives JSON-RPC and responds via SSE
  post "/mcp/messages" do
    conn = fetch_query_params(conn)
    session_id = conn.query_params["session_id"]

    if session_id && Acs.MCP.SSESessionManager.alive?(session_id) do
      handle_mcp_message(conn, session_id)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "Invalid or missing session_id"}))
      |> halt()
    end
  end

  # MCP Endpoints
  post "/mcp/v1/messages" do
    handle_json_rpc_http(conn)
  end

  # Streamable HTTP clients GET the endpoint to open the server→client notification
  # stream. We only reply to POSTs, and the spec requires 405 here — a 404 is read as
  # a terminated session, which makes clients (e.g. Cursor) tombstone the transport.
  get "/mcp/v1/messages" do
    conn
    |> put_resp_header("allow", "POST")
    |> put_resp_content_type("application/json")
    |> send_resp(405, Jason.encode!(%{error: "Method not allowed"}))
  end

  # Log ingestion from external services
  post "/api/logs/ingest" do
    body = conn.body_params

    case body do
      %{"logs" => logs} when is_list(logs) ->
        if length(logs) > @max_log_batch do
          Acs.Observability.Events.warning("log ingest batch too large",
            action: "log_ingest",
            status: "413",
            org: conn.assigns[:agent_org_id],
            count: length(logs),
            error_type: "batch_too_large"
          )

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(413, Jason.encode!(%{error: "Batch too large (max #{@max_log_batch})"}))
        else
          results = Enum.map(logs, &process_log_entry/1)
          success_count = Enum.count(results, &(&1 == :ok))

          Acs.Observability.Events.info("log ingest batch stored",
            action: "log_ingest",
            status: "ok",
            org: conn.assigns[:agent_org_id],
            count: success_count,
            tags: ["ingest"]
          )

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{status: "ok", stored: success_count, total: length(logs)})
          )
        end

      %{} = log_entry when map_size(log_entry) > 0 ->
        case process_log_entry(log_entry) do
          :ok ->
            Acs.Observability.Events.info("log ingest entry stored",
              action: "log_ingest",
              status: "ok",
              org: conn.assigns[:agent_org_id],
              count: 1,
              tags: ["ingest"]
            )

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{status: "ok"}))

          {:error, _reason} ->
            Acs.Observability.Events.warning("log ingest entry failed",
              action: "log_ingest",
              status: "error",
              org: conn.assigns[:agent_org_id],
              error_type: "store_failed"
            )

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              500,
              Jason.encode!(%{status: "error", reason: "Failed to store log entry"})
            )
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            error:
              "Invalid log entry. Expected JSON with 'message' and optional 'level', 'service', 'component', 'metadata'"
          })
        )
    end
  end

  # Log query endpoint for external services
  get "/api/logs" do
    conn = fetch_query_params(conn)

    unless conn.assigns[:agent_role] in ~w(admin service) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{error: "Access denied: log query requires admin or service role"})
      )
      |> halt()
    end

    params = conn.query_params

    opts = [org: conn.assigns[:agent_org_id]]

    opts =
      case params["level"] do
        nil ->
          opts

        level ->
          case parse_log_level(level) do
            {:ok, atom} ->
              Keyword.put(opts, :level, atom)

            :error ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                400,
                Jason.encode!(%{
                  error: "Invalid level: must be one of debug, info, warning, error"
                })
              )
              |> halt()
          end
      end

    opts =
      if params["limit"] do
        case Integer.parse(params["limit"]) do
          {n, ""} when n > 0 ->
            Keyword.put(opts, :limit, n)

          _ ->
            conn
            |> send_resp(400, Jason.encode!(%{error: "Invalid limit: must be positive integer"}))
            |> halt()
        end
      else
        opts
      end

    opts =
      if params["component"], do: Keyword.put(opts, :component, params["component"]), else: opts

    opts = if params["search"], do: Keyword.put(opts, :search, params["search"]), else: opts
    opts = if params["service"], do: Keyword.put(opts, :service, params["service"]), else: opts

    opts =
      if params["workflow_id"],
        do: Keyword.put(opts, :workflow_id, params["workflow_id"]),
        else: opts

    opts =
      if params["execution_id"],
        do: Keyword.put(opts, :execution_id, params["execution_id"]),
        else: opts

    opts = if params["since"], do: Keyword.put(opts, :since, params["since"]), else: opts
    opts = if params["until"], do: Keyword.put(opts, :until, params["until"]), else: opts

    opts =
      if params["offset"] do
        case Integer.parse(params["offset"]) do
          {n, ""} when n >= 0 ->
            Keyword.put(opts, :offset, n)

          _ ->
            conn
            |> send_resp(
              400,
              Jason.encode!(%{error: "Invalid offset: must be non-negative integer"})
            )
            |> halt()
        end
      else
        opts
      end

    opts = if params["compact"] == "true", do: Keyword.put(opts, :compact, true), else: opts

    mode = params["mode"] || "list"

    result = LogStore.get_logs(opts, mode)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
  end

  # Log context endpoint - get entries surrounding a specific log entry
  get "/api/logs/context/:id" do
    conn = fetch_query_params(conn)

    unless conn.assigns[:agent_role] in ~w(admin service) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{error: "Access denied: log query requires admin or service role"})
      )
      |> halt()
    end

    entry_id =
      case Integer.parse(id) do
        {n, ""} ->
          n

        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{error: "Invalid entry id: must be an integer"}))
          |> halt()
      end

    window_size =
      case conn.query_params["window_size"] do
        nil ->
          30

        ws ->
          case Integer.parse(ws) do
            {n, ""} when n > 0 ->
              n

            _ ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                400,
                Jason.encode!(%{error: "Invalid window_size: must be positive integer"})
              )
              |> halt()
          end
      end

    result = LogStore.get_context_before(entry_id, window_size, conn.assigns[:agent_org_id])

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
  end

  # Health check — DB probe removed so Neon compute can suspend when idle.
  # Assume the database is healthy; failures surface via app logs and Axiom.
  get "/mcp/health" do
    conn
    |> put_private(:phoenix_log_level, false)
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        status: "healthy",
        database: true,
        timestamp: DateTime.utc_now()
      })
    )
  end

  # Task API for external apps
  post "/api/tasks" do
    body = conn.body_params

    case body do
      %{"title" => title, "created_by_agent" => agent_id}
      when is_binary(title) and is_binary(agent_id) ->
        safe_body =
          body
          |> Map.drop(["org", "org_id", "cluster"])
          |> Map.put("org", conn.assigns[:agent_org_id])

        case Acs.create_task(safe_body, agent_id) do
          {:ok, task} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(%{status: "created", task_id: task.id, task: task}))

          {:warn, task, similar} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              201,
              Jason.encode!(%{
                status: "created_with_warning",
                task_id: task.id,
                task: task,
                similar_tasks: similar
              })
            )

          {:error, _reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{status: "error", reason: "Failed to create task"}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "Missing required fields: title, created_by_agent"})
        )
    end
  end

  # Bump/update a task
  patch "/api/tasks/:id" do
    body = conn.body_params

    case Acs.bump_task(id, body || %{}) do
      {:ok, task} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{status: "updated", task_id: task.id, event_count: task.event_count})
        )

      {:error, reason} ->
        status = if reason == :task_not_found, do: 404, else: 400

        message =
          if reason == :task_not_found, do: "Task not found", else: "Failed to update task"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(%{status: "error", reason: message}))
    end
  end

  # Catch-all
  match _ do
    conn |> send_resp(404, ~s({"error": "Not found"}))
  end

  defp handle_mcp_message(conn, session_id) do
    case conn.body_params do
      %{} = params ->
        case Acs.MCP.ClientSession.bind(session_id, fn ->
               Protocol.handle_message(
                 params,
                 conn.assigns[:agent_role],
                 conn.assigns[:agent_org_id],
                 conn.assigns[:agent_permissions],
                 conn.assigns[:agent_allowed_teams],
                 conn.assigns[:agent_allowed_projects],
                 conn.assigns[:agent_identity],
                 conn.assigns[:agent_authority_level],
                 conn.assigns[:agent_authority_sort_order]
               )
             end) do
          # MCP notifications (e.g. notifications/initialized) have no JSON-RPC reply.
          # Emitting `data: null` on the SSE stream breaks Cursor's Zod parser.
          {:ok, nil} ->
            conn |> send_resp(202, "")

          {:ok, response} ->
            Logger.debug("MCP SSE: response=#{inspect(response)}")
            Acs.MCP.SSESessionManager.send_response(session_id, response)
            conn |> send_resp(202, "")

          {:error, reason} ->
            error = Protocol.error_response(nil, -32700, "Parse error", reason)
            Acs.MCP.SSESessionManager.send_response(session_id, error)
            conn |> send_resp(202, "")
        end

      _ ->
        conn |> send_resp(400, ~s({"error": "Invalid JSON"}))
    end
  end

  # Claude / Streamable HTTP clients POST JSON-RPC to the SSE URL.
  # If a legacy session_id is present, reuse the SSE reply path; otherwise
  # answer inline like /mcp/v1/messages.
  defp handle_streamable_post(conn) do
    conn = fetch_query_params(conn)
    session_id = session_id_from_conn(conn)

    if is_binary(session_id) and session_id != "" and
         Acs.MCP.SSESessionManager.alive?(session_id) do
      Acs.MCP.ClientSession.set_sticky(session_id, true)
      handle_mcp_message(conn, session_id)
    else
      handle_json_rpc_http(conn)
    end
  end

  defp handle_json_rpc_http(conn) do
    conn = fetch_query_params(conn)
    session_id = session_id_from_conn(conn) || generate_session_id()
    Acs.MCP.ClientSession.set_sticky(session_id, is_binary(session_id_from_conn(conn)))
    seed_http_audience(conn, session_id)

    Logger.debug("MCP HTTP: received request on #{conn.request_path}")

    case conn.body_params do
      %{} = params ->
        case Acs.MCP.ClientSession.bind(session_id, fn ->
               Protocol.handle_message(
                 params,
                 conn.assigns[:agent_role],
                 conn.assigns[:agent_org_id],
                 conn.assigns[:agent_permissions],
                 conn.assigns[:agent_allowed_teams],
                 conn.assigns[:agent_allowed_projects],
                 conn.assigns[:agent_identity],
                 conn.assigns[:agent_authority_level],
                 conn.assigns[:agent_authority_sort_order]
               )
             end) do
          {:ok, nil} ->
            # notifications/initialized — no JSON-RPC body
            conn
            |> put_resp_content_type("application/json")
            |> put_resp_header("x-mcp-session-id", session_id)
            |> send_resp(202, "")

          {:ok, response} ->
            Logger.debug("MCP HTTP: response=#{inspect(response)}")

            conn
            |> put_resp_content_type("application/json")
            |> put_resp_header("x-mcp-session-id", session_id)
            |> send_resp(200, Jason.encode!(response))

          {:error, reason} ->
            error = Protocol.error_response(nil, -32700, "Parse error", reason)

            conn
            |> put_resp_content_type("application/json")
            |> put_resp_header("x-mcp-session-id", session_id)
            |> send_resp(200, Jason.encode!(error))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Invalid JSON"}))
    end
  end

  defp seed_http_audience(conn, session_id) do
    endpoint = Acs.MCP.MemoryProvenance.normalize_endpoint(conn.request_path)

    case Acs.MCP.Audience.from_request(conn.request_path, conn.query_params) do
      audience when audience in [:chat, :coding] ->
        Acs.MCP.ClientSession.seed_mcp_connect(
          session_id,
          endpoint || conn.request_path,
          audience
        )

      _ ->
        if endpoint do
          Acs.MCP.ClientSession.seed_mcp_connect(session_id, endpoint, key_kind_audience(conn))
        end
    end
  end

  defp key_kind_audience(conn) do
    case conn.assigns[:agent_kind] do
      "chat" -> :chat
      _ -> :coding
    end
  end

  defp open_sse(conn) do
    conn = fetch_query_params(conn)
    session_id = generate_sse_session_id()
    endpoint = Acs.MCP.MemoryProvenance.normalize_endpoint(conn.request_path)

    case Acs.MCP.Audience.from_request(conn.request_path, conn.query_params) do
      audience when audience in [:chat, :coding] ->
        Acs.MCP.ClientSession.seed_mcp_connect(
          session_id,
          endpoint || conn.request_path,
          audience
        )

      _ ->
        # Still record the connect path for provenance when URL does not force audience.
        if endpoint do
          Acs.MCP.ClientSession.seed_mcp_connect(session_id, endpoint, key_kind_audience(conn))
        end
    end

    Acs.MCP.ClientSession.set_sticky(session_id, true)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case chunk(
           conn,
           "event: endpoint\ndata: /mcp/messages?session_id=#{session_id}\n\n"
         ) do
      {:ok, conn} ->
        :ok = Acs.MCP.SSESessionManager.register(session_id, self())
        sse_loop(conn, session_id)

      {:error, _reason} ->
        handle_sse_close(session_id, conn)
    end
  end

  defp generate_session_id do
    "http_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  # Streamable HTTP spec: the server returns the session in the `x-mcp-session-id`
  # response header and clients echo it back on subsequent requests. Reuse it so
  # `ClientSession.current_id()` stays stable across a client session — otherwise a
  # fresh id is generated per request and per-session state (e.g. the qualified agent
  # name) keeps rotating.
  defp session_id_from_conn(conn) do
    case Plug.Conn.get_req_header(conn, "x-mcp-session-id") do
      [id | _] when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp generate_sse_session_id do
    "sse_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
  end

  defp sse_loop(conn, session_id) do
    receive do
      # Defense: never write `data: null` — Cursor rejects it as invalid JSON-RPC.
      {:send_response, nil} ->
        sse_loop(conn, session_id)

      {:send_response, response} ->
        case chunk(conn, "event: message\ndata: #{Jason.encode!(response)}\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _reason} -> handle_sse_close(session_id, conn)
        end

      {:send_event, event, data} ->
        case chunk(conn, "event: #{event}\ndata: #{data}\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _reason} -> handle_sse_close(session_id, conn)
        end

      :close ->
        Acs.MCP.SSESessionManager.unregister(session_id)
        conn
    after
      30_000 ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _reason} -> handle_sse_close(session_id, conn)
        end
    end
  end

  defp handle_sse_close(session_id, conn) do
    Acs.MCP.SSESessionManager.unregister(session_id)
    conn
  end

  defp process_log_entry(log_entry) do
    level = parse_log_level(Map.get(log_entry, "level", "info"))
    service = Map.get(log_entry, "service", "unknown")
    component = Map.get(log_entry, "component", "external")
    message = Map.get(log_entry, "message", "")

    metadata =
      log_entry
      |> Map.get("metadata", %{})
      |> normalize_metadata()
      |> enrich_metadata(service, component)
      |> Map.put(:org, Acs.Org.current())

    LogStore.store_log(level, service, component, message, metadata)
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn
      {key, value} when is_atom(key) ->
        {key, value}

      {key, value} when is_binary(key) ->
        {to_atom(key), value}
    end)
  end

  defp normalize_metadata(_), do: %{}

  defp enrich_metadata(metadata, service, component) do
    # System tags from service + component segments
    system_tags = [service | extract_segments(component)]

    # User tags from structured metadata fields
    tags =
      []
      |> add_tag_if(metadata[:call_type], "call_type")
      |> add_tag_if(metadata[:status], "status")
      |> add_tag_if(metadata[:action], "action")
      |> add_tag_if(metadata[:error_type], "error_type")
      |> add_tag_if(metadata[:agent_name], "agent")

    # Forward any existing tags from the source
    existing_tags = List.wrap(metadata[:tags] || metadata["tags"])
    existing_sys = List.wrap(metadata[:system_tags] || metadata["system_tags"])

    metadata
    |> Map.put(:system_tags, Enum.uniq(system_tags ++ existing_sys))
    |> Map.put(:tags, Enum.uniq(tags ++ existing_tags))
  end

  defp extract_segments(component) when is_binary(component) do
    component
    |> String.split(~r{[/:.\s]})
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.flat_map(fn seg -> [seg, "module:#{seg}"] end)
  end

  defp extract_segments(_), do: []

  defp add_tag_if(list, nil, _prefix), do: list

  defp add_tag_if(list, value, prefix) when is_binary(value) do
    ["#{prefix}:#{String.downcase(value)}" | list]
  end

  defp add_tag_if(list, value, prefix) do
    ["#{prefix}:#{String.downcase(to_string(value))}" | list]
  end

  # Converts string key to atom safely - uses existing atom if available,
  # falls back to creating atom for known/safe keys only
  defp to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp to_atom(key), do: key

  defp parse_log_level(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> {:ok, :debug}
      "info" -> {:ok, :info}
      "warn" -> {:ok, :warning}
      "warning" -> {:ok, :warning}
      "error" -> {:ok, :error}
      _ -> :error
    end
  end
end

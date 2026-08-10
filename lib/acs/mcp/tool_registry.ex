defmodule Acs.MCP.ToolRegistry do
  @moduledoc false

  use GenServer
  require Logger

  @call_timeout 180_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def list_tools(category \\ nil, org \\ Acs.Org.current()),
    do: GenServer.call(__MODULE__, {:list_tools, category, org})

  def list_tools_mcp(agent_role, org \\ Acs.Org.current(), permissions \\ nil, audience \\ nil)

  def list_tools_mcp(agent_role, org, permissions, audience)
      when is_binary(agent_role) and is_binary(org),
      do: GenServer.call(__MODULE__, {:list_tools_mcp, agent_role, org, permissions, audience})

  def list_tools_mcp(_, _, _, _), do: []

  def list_categories(org \\ Acs.Org.current()),
    do: GenServer.call(__MODULE__, {:list_categories, org})

  def get_tool(name, org \\ Acs.Org.current()),
    do: GenServer.call(__MODULE__, {:get_tool, name, org})

  @doc "Legacy internal execution API. External MCP callers must use invoke/3."
  def call_tool(name, args) when is_map(args),
    do: GenServer.call(__MODULE__, {:call_tool, name, args}, @call_timeout)

  @doc "Atomically resolves, authorizes, and invokes a tool using trusted authentication context."
  def invoke(name, user_args, auth_context)
      when is_binary(name) and is_map(user_args) and is_map(auth_context),
      do: GenServer.call(__MODULE__, {:invoke, name, user_args, auth_context}, @call_timeout)

  def refresh, do: GenServer.call(__MODULE__, :refresh, 30_000)
  def stats(org \\ Acs.Org.current()), do: GenServer.call(__MODULE__, {:stats, org})
  def list_plugins(org \\ Acs.Org.current()), do: GenServer.call(__MODULE__, {:list_plugins, org})

  def authorize_tool(
        name,
        agent_role,
        agent_permissions \\ nil,
        org \\ Acs.Org.current(),
        audience \\ nil
      )

  def authorize_tool(name, agent_role, agent_permissions, org, audience),
    do:
      GenServer.call(
        __MODULE__,
        {:authorize_tool, name, agent_role, agent_permissions, org, audience}
      )

  def register_tool(tool_def),
    do: GenServer.call(__MODULE__, {:register_tool, tool_def, Acs.Org.current()})

  def register_tool(tool_def, org),
    do: GenServer.call(__MODULE__, {:register_tool, tool_def, org})

  def approve_request(request_id, approved_by, org \\ Acs.Org.current()),
    do: GenServer.call(__MODULE__, {:approve_request, request_id, approved_by, org})

  def reject_request(request_id, approved_by, org \\ Acs.Org.current()),
    do: GenServer.call(__MODULE__, {:reject_request, request_id, approved_by, org})

  @impl true
  def init(_opts) do
    state = %{snapshot: empty_snapshot(), last_refresh_error: nil}

    {snapshot, errors} = refresh_snapshot(state.snapshot)

    if errors != [], do: log_refresh_errors(errors)
    Logger.info("ToolRegistry initialized with #{snapshot_tool_count(snapshot)} scoped tools")
    {:ok, %{state | snapshot: snapshot, last_refresh_error: format_refresh_errors(errors)}}
  end

  @impl true
  def handle_call({:list_tools, category, org}, _from, state) do
    scope = effective_scope(state.snapshot, org)

    yaml_tools =
      scope.tools
      |> Map.values()
      |> filter_category(category)
      |> Enum.sort_by(& &1["name"])

    core_tools =
      Acs.MCP.Tools.list_tools()
      |> Enum.filter(fn tool ->
        is_nil(category) or Acs.MCP.Tools.tool_category(tool["name"]) == category
      end)
      |> Enum.map(fn tool ->
        Map.put(tool, "app", "steward")
        |> Map.put("category", Acs.MCP.Tools.tool_category(tool["name"]) || "uncategorized")
      end)

    {:reply, yaml_tools ++ core_tools, state}
  end

  def handle_call({:list_tools_mcp, role, org, permissions, audience}, _from, state) do
    yaml_tools =
      state.snapshot
      |> effective_scope(org)
      |> Map.fetch!(:tools)
      |> Map.values()
      |> Enum.filter(&authorized?(&1, &1["name"], role, permissions))
      |> Enum.filter(&chat_yaml_allowed?(&1["name"], audience))
      |> Enum.map(&Map.take(&1, ["name", "description", "inputSchema"]))
      |> Enum.sort_by(& &1["name"])

    core_tools =
      Acs.MCP.Tools.list_tools()
      |> Enum.filter(&Acs.MCP.CoreToolRoles.authorized?(&1["name"], role, audience))

    tools =
      (yaml_tools ++ core_tools)
      |> Enum.map(&Acs.MCP.CoreToolRoles.with_eager_meta/1)
      |> Enum.sort_by(&Acs.MCP.CoreToolRoles.list_sort_key/1)

    {:reply, tools, state}
  end

  def handle_call({:list_categories, org}, _from, state) do
    categories =
      Map.keys(effective_scope(state.snapshot, org).by_category) ++
        (Acs.MCP.Tools.list_tools() |> Enum.map(&Acs.MCP.Tools.tool_category(&1["name"])))

    {:reply, categories |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(), state}
  end

  def handle_call({:get_tool, name, org}, _from, state),
    do: {:reply, Map.get(effective_scope(state.snapshot, org).tools, name), state}

  def handle_call({:authorize_tool, name, role, permissions, org, audience}, _from, state) do
    {:reply, authorize(state.snapshot, name, role, permissions, org, audience), state}
  end

  def handle_call(:refresh, _from, state) do
    {snapshot, errors} = refresh_snapshot(state.snapshot)
    Acs.broadcast(:tools_refresh, %{})

    case errors do
      [] ->
        {:reply, :ok, %{state | snapshot: snapshot, last_refresh_error: nil}}

      _ ->
        log_refresh_errors(errors)
        reason = format_refresh_errors(errors)
        {:reply, {:error, reason}, %{state | snapshot: snapshot, last_refresh_error: reason}}
    end
  end

  def handle_call({:stats, org}, _from, state) do
    scope = effective_scope(state.snapshot, org)
    core_tools = Acs.MCP.Tools.list_tools()

    {:reply,
     %{
       total_tools: map_size(scope.tools) + length(core_tools),
       total_apps: map_size(scope.by_app) + 1,
       categories:
         (Map.keys(scope.by_category) ++
            Enum.map(core_tools, &Acs.MCP.Tools.tool_category(&1["name"])))
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq()
         |> Enum.sort(),
       apps: Map.new(scope.by_app, fn {app, tools} -> {app, length(tools)} end)
     }, state}
  end

  def handle_call({:list_plugins, org}, _from, state) do
    scope = effective_scope(state.snapshot, org)

    plugins =
      scope.by_app
      |> Enum.map(fn {app, tools} ->
        meta = Map.get(scope.apps_meta, app, %{})

        %{
          app: app,
          version: meta["version"],
          plugin: meta["plugin"],
          tool_count: length(tools),
          tools: tools |> Enum.map(& &1["name"]) |> Enum.sort()
        }
      end)
      |> Enum.sort_by(& &1.app)

    {:reply, {:ok, %{plugins: plugins, count: length(plugins)}}, state}
  end

  def handle_call({:register_tool, tool_def, org}, _from, state) do
    case register_runtime_tool(state.snapshot, tool_def, org) do
      {:ok, snapshot} ->
        Acs.broadcast(:tools_refresh, %{})
        {:reply, :ok, %{state | snapshot: snapshot}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:approve_request, request_id, approved_by, org}, _from, state) do
    case Acs.Org.with_current(org, fn ->
           Acs.MCP.ToolRequests.approve_request(request_id, approved_by)
         end) do
      {:ok, request} ->
        definition = Acs.MCP.ToolRequest.decode_definition(request.definition)

        tool_def =
          %{
            "category" => request.category || "requested",
            "level" => 2,
            "app" => "requested",
            "base_url" => "",
            "endpoint" => nil,
            "method" => nil,
            "handler" => nil,
            "params" => definition["params"] || []
          }
          |> Map.merge(definition)

        case register_runtime_tool(state.snapshot, tool_def, org) do
          {:ok, snapshot} ->
            Acs.broadcast(:tool_request_approved, %{
              request_id: request_id,
              name: tool_def["name"],
              approved_by: approved_by
            })

            {:reply, {:ok, %{status: "approved", tool: tool_def["name"], request_id: request_id}},
             %{state | snapshot: snapshot}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, "Failed to approve: #{inspect(reason)}"}, state}
    end
  end

  def handle_call({:reject_request, request_id, approved_by, org}, _from, state) do
    case Acs.Org.with_current(org, fn ->
           Acs.MCP.ToolRequests.reject_request(request_id, approved_by)
         end) do
      {:ok, request} ->
        Acs.broadcast(:tool_request_rejected, %{
          request_id: request_id,
          name: request.name,
          rejected_by: approved_by
        })

        {:reply, {:ok, %{status: "rejected", request_id: request_id}}, state}

      {:error, reason} ->
        {:reply, {:error, "Failed to reject: #{inspect(reason)}"}, state}
    end
  end

  def handle_call({:call_tool, name, args}, _from, state) do
    credential_org = args["_auth_credential_org_id"] || args["_auth_org_id"]
    resource_org = args["_auth_org_id"] || credential_org
    role = args["_auth_role"]
    permissions = args["_auth_permissions"] || []

    with true <- valid_org?(credential_org) and valid_org?(resource_org) and is_binary(role),
         :ok <- authorize(state.snapshot, name, role, permissions, credential_org, nil) do
      if name == "write_tool" do
        commit_dynamic_tool(state, args, credential_org)
      else
        {:reply, execute_and_log(state.snapshot, name, args, credential_org, resource_org), state}
      end
    else
      false -> {:reply, {:error, "Missing authentication context"}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:invoke, name, user_args, auth_context}, _from, state) do
    with {:ok, auth} <- normalize_auth_context(auth_context),
         :ok <-
           authorize(
             state.snapshot,
             name,
             auth.role,
             auth.permissions,
             auth.credential_org,
             auth[:audience]
           ) do
      args = inject_auth_context(user_args, auth)

      if name == "write_tool" do
        commit_dynamic_tool(state, args, auth.credential_org)
      else
        {:reply,
         execute_and_log(state.snapshot, name, args, auth.credential_org, auth.resource_org),
         state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp commit_dynamic_tool(state, args, credential_org) do
    case Acs.MCP.Tools.DynamicTools.persist_tool(args) do
      {:ok, result, rollback} ->
        {snapshot, errors} = refresh_snapshot(state.snapshot)

        scope_error =
          Enum.find(errors, fn {scope, _reason} -> scope == {:tenant, credential_org} end)

        if scope_error do
          rollback_result = Acs.MCP.Tools.DynamicTools.rollback_tool(rollback)
          {_scope, reason} = scope_error

          message =
            case rollback_result do
              :ok ->
                "Tool validation failed; write rolled back: #{reason}"

              {:error, rollback_reason} ->
                Logger.error("Tenant tool rollback failed: #{inspect(rollback_reason)}")

                "Tool validation failed and rollback failed: #{reason}; #{inspect(rollback_reason)}"
            end

          {:reply, {:error, message}, state}
        else
          Acs.broadcast(:tools_refresh, %{})
          if errors != [], do: log_refresh_errors(errors)

          {:reply, {:ok, Map.put(result, :reloaded, true)},
           %{state | snapshot: snapshot, last_refresh_error: format_refresh_errors(errors)}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Tools spawned via Task.async during handle_call deliver {ref, result} here.
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_info(:refresh_tools, state) do
    {snapshot, errors} = refresh_snapshot(state.snapshot)
    Acs.broadcast(:tools_refresh, %{})
    if errors != [], do: log_refresh_errors(errors)

    {:noreply,
     %{
       state
       | snapshot: snapshot,
         last_refresh_error: format_refresh_errors(errors)
     }}
  end

  defp refresh_snapshot(previous) do
    grouped_sources = Enum.group_by(Acs.MCP.ToolLoader.sources(), &source_scope/1)

    expected_tenants =
      grouped_sources
      |> Map.keys()
      |> Enum.flat_map(fn
        {:tenant, org} -> [org]
        :shared -> []
      end)
      |> MapSet.new()

    base = %{
      previous
      | shared:
          if(Map.has_key?(grouped_sources, :shared), do: previous.shared, else: empty_scope()),
        tenants: Map.take(previous.tenants, MapSet.to_list(expected_tenants))
    }

    Enum.reduce(grouped_sources, {base, []}, fn {scope, sources}, {snapshot, errors} ->
      with {:ok, configs} <- Acs.MCP.ToolLoader.load_scope(sources),
           {:ok, tools} <- configs_to_tools(configs) do
        {put_loaded_scope(snapshot, scope, tools), errors}
      else
        {:error, reason} -> {snapshot, [{scope, reason} | errors]}
      end
    end)
  end

  defp source_scope({:shared, _path}), do: :shared
  defp source_scope({:tenant, org, _path}), do: {:tenant, org}
  defp source_scope({:tenant_db, org}), do: {:tenant, org}

  defp put_loaded_scope(snapshot, :shared, tools),
    do: %{snapshot | shared: scope_from_tools(tools)}

  defp put_loaded_scope(snapshot, {:tenant, org}, tools),
    do: %{snapshot | tenants: Map.put(snapshot.tenants, org, scope_from_tools(tools))}

  defp format_refresh_errors([]), do: nil

  defp format_refresh_errors(errors) do
    errors
    |> Enum.reverse()
    |> Enum.map_join("; ", fn {scope, reason} -> "#{inspect(scope)}: #{reason}" end)
  end

  defp log_refresh_errors(errors) do
    Enum.each(errors, fn {scope, reason} ->
      Logger.warning("ToolRegistry retained last-known-good #{inspect(scope)} scope: #{reason}")
    end)
  end

  defp configs_to_tools(configs) do
    configs
    |> Enum.flat_map(&Acs.MCP.ToolLoader.to_mcp_tools/1)
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, tools} ->
      cond do
        Acs.MCP.Tools.has_tool?(tool["name"]) ->
          {:halt, {:error, "Tool '#{tool["name"]}' collides with a reserved core tool"}}

        true ->
          {:cont, {:ok, tools ++ [tool]}}
      end
    end)
  end

  defp empty_snapshot, do: %{shared: empty_scope(), tenants: %{}}

  defp effective_scope(snapshot, org) do
    tenant = Map.get(snapshot.tenants, org, empty_scope())
    scope_from_tools(Map.values(snapshot.shared.tools) ++ Map.values(tenant.tools))
  end

  defp scope_from_tools(tools) do
    tools = Map.new(tools, &{&1["name"], &1})

    by_category =
      tools
      |> Map.values()
      |> Enum.group_by(&(&1["category"] || "uncategorized"))
      |> Map.new(fn {category, entries} -> {category, Enum.sort_by(entries, & &1["name"])} end)

    by_app =
      tools
      |> Map.values()
      |> Enum.group_by(&(&1["app"] || "unknown"))
      |> Map.new(fn {app, entries} -> {app, Enum.sort_by(entries, & &1["name"])} end)

    apps_meta =
      Map.new(by_app, fn {app, [tool | _]} -> {app, tool["_app_meta"] || %{}} end)

    %{tools: tools, by_category: by_category, by_app: by_app, apps_meta: apps_meta}
  end

  defp empty_scope, do: %{tools: %{}, by_category: %{}, by_app: %{}, apps_meta: %{}}

  defp register_runtime_tool(snapshot, tool_def, org)
       when is_map(tool_def) and is_binary(org) and org != "" do
    name = tool_def["name"]
    scope = Map.get(snapshot.tenants, org, empty_scope())

    cond do
      not is_binary(name) or name == "" ->
        {:error, "Tool name is required"}

      Acs.MCP.Tools.has_tool?(name) ->
        {:error, "Tool '#{name}' is reserved"}

      is_binary(tool_def["handler"]) and tool_def["handler"] != "" ->
        {:error, "Tenant runtime tools cannot define internal handlers"}

      not is_binary(tool_def["endpoint"]) or tool_def["endpoint"] == "" ->
        {:error, "Tenant runtime tools must define an endpoint"}

      Map.has_key?(scope.tools, name) ->
        {:error, "Tool '#{name}' already exists for tenant '#{org}'"}

      true ->
        tool =
          tool_def
          |> Map.delete("org")
          |> Map.put("_scope", {:tenant, org})
          |> Map.put("_source", %{path: "runtime", scope: {:tenant, org}, digest: nil})

        tenant = scope_from_tools(Map.values(scope.tools) ++ [tool])
        {:ok, %{snapshot | tenants: Map.put(snapshot.tenants, org, tenant)}}
    end
  end

  defp register_runtime_tool(_snapshot, _tool_def, _org),
    do: {:error, "Missing organization context"}

  defp authorize(snapshot, name, role, permissions, credential_org, audience) do
    case resolve(snapshot, credential_org, name) do
      {:core, _} ->
        if Acs.MCP.CoreToolRoles.authorized?(name, role, audience),
          do: :ok,
          else: {:error, "Role '#{role}' is not authorized to use tool '#{name}'"}

      {:tool, tool} ->
        cond do
          chat_audience?(audience) ->
            {:error, "Role '#{role}' is not authorized to use tool '#{name}'"}

          authorized?(tool, name, role, permissions) ->
            :ok

          true ->
            authorization_error(tool, name, role, permissions)
        end

      :missing ->
        {:error, "Unknown tool: #{name}"}
    end
  end

  defp chat_yaml_allowed?(_name, audience), do: not chat_audience?(audience)

  defp chat_audience?(audience), do: audience in [:chat, "chat", :knowledge, "knowledge"]

  defp resolve(snapshot, credential_org, name) do
    cond do
      Acs.MCP.Tools.has_tool?(name) -> {:core, name}
      tool = get_in(snapshot, [:tenants, credential_org, :tools, name]) -> {:tool, tool}
      tool = get_in(snapshot, [:shared, :tools, name]) -> {:tool, tool}
      true -> :missing
    end
  end

  defp authorized?(tool, _name, role, permissions) do
    role in (tool["roles"] || ["admin"]) and
      Enum.all?(tool["permissions"] || [], &(&1 in List.wrap(permissions)))
  end

  defp authorization_error(tool, name, role, permissions) do
    cond do
      role not in (tool["roles"] || ["admin"]) ->
        {:error, "Role '#{role}' is not authorized to use tool '#{name}'"}

      true ->
        missing = Enum.reject(tool["permissions"] || [], &(&1 in List.wrap(permissions)))
        {:error, "Missing required permissions for '#{name}': #{Enum.join(missing, ", ")}"}
    end
  end

  defp execute_and_log(snapshot, name, args, credential_org, resource_org) do
    missing? = resolve(snapshot, credential_org, name) == :missing
    started_at = System.monotonic_time(:millisecond)
    result = execute(snapshot, name, args, credential_org, resource_org)
    latency_ms = System.monotonic_time(:millisecond) - started_at

    maybe_log_operation(name, result, latency_ms, args, discovery: missing?)

    result
  end

  defp execute(snapshot, "list_plugins", args, credential_org, _resource_org) do
    {:ok, plugins_result(effective_scope(snapshot, credential_org), args)}
  end

  defp execute(snapshot, "help", args, credential_org, _resource_org) do
    {:ok, help_result(effective_scope(snapshot, credential_org), args)}
  end

  defp execute(snapshot, name, args, credential_org, resource_org) do
    case resolve(snapshot, credential_org, name) do
      {:core, _} ->
        Acs.Org.with_current(resource_org, fn ->
          safe_execute(fn -> Acs.MCP.Tools.call_tool(name, args) end)
        end)

      {:tool, tool} ->
        Acs.Org.with_current(resource_org, fn ->
          safe_execute(fn -> execute_tool(tool, args) end)
        end)

      :missing ->
        {:error, "Unknown tool: #{name}"}
    end
  end

  defp execute_tool(tool, args) do
    cond do
      is_binary(tool["handler"]) and tool["handler"] != "" ->
        with {:ok, module} <- fetch_handler_module(tool["handler"]) do
          module
          |> apply(:call_tool, [tool["name"], args])
          |> normalize_tool_result()
        end

      is_binary(tool["endpoint"]) and is_binary(tool["base_url"]) and tool["base_url"] != "" ->
        Acs.MCP.Bridge.call_tool(tool, args)

      true ->
        {:error, "Tool '#{tool["name"]}' has no executable handler or endpoint"}
    end
  end

  defp plugins_result(scope, args) do
    role = args["_auth_role"]
    permissions = args["_auth_permissions"]

    plugins =
      scope.by_app
      |> Enum.map(fn {app, tools} ->
        visible = Enum.filter(tools, &authorized?(&1, &1["name"], role, permissions))
        meta = Map.get(scope.apps_meta, app, %{})

        %{
          app: app,
          version: meta["version"],
          plugin: meta["plugin"],
          tool_count: length(visible),
          tools: Enum.map(visible, & &1["name"])
        }
      end)
      |> Enum.reject(&(&1.tool_count == 0))
      |> Enum.sort_by(& &1.app)

    %{plugins: plugins, count: length(plugins)}
  end

  defp help_result(scope, args) do
    category = args["category"]
    level = args["level"]
    role = args["_auth_role"]
    permissions = args["_auth_permissions"]
    audience = args["_auth_audience"]

    tools =
      ((scope.tools
        |> Map.values()
        |> Enum.filter(&authorized?(&1, &1["name"], role, permissions))
        |> Enum.filter(&chat_yaml_allowed?(&1["name"], audience))) ++
         (Acs.MCP.Tools.list_tools()
          |> Enum.filter(&Acs.MCP.CoreToolRoles.authorized?(&1["name"], role, audience))
          |> Enum.map(fn tool ->
            tool
            |> Map.put("app", "steward")
            |> Map.put("category", Acs.MCP.Tools.tool_category(tool["name"]) || "uncategorized")
          end)))
      |> Enum.filter(fn tool ->
        (is_nil(category) or tool["category"] == category) and
          (is_nil(level) or (tool["level"] || 2) <= level)
      end)

    tools_by_category =
      tools
      |> Enum.group_by(&(&1["category"] || "uncategorized"))
      |> Map.new(fn {tool_category, entries} ->
        {tool_category,
         entries
         |> Enum.map(fn tool ->
           %{
             name: tool["name"],
             level: tool["level"] || 2,
             description: tool["description"],
             params: Enum.map(tool["params"] || [], & &1["name"]),
             required_params:
               tool["params"]
               |> Kernel.||([])
               |> Enum.filter(& &1["required"])
               |> Enum.map(& &1["name"])
           }
         end)
         |> Enum.sort_by(& &1.name)}
      end)

    categories = Map.keys(tools_by_category) |> Enum.sort()

    %{
      total_tools: length(tools),
      categories: %{available: categories, filtered: categories},
      tools: tools_by_category
    }
  end

  defp normalize_tool_result({:ok, _} = result), do: result
  defp normalize_tool_result({:error, _} = result), do: result
  defp normalize_tool_result(:ok), do: {:ok, %{status: "ok"}}
  defp normalize_tool_result(nil), do: {:ok, %{status: "ok"}}
  defp normalize_tool_result(other), do: {:ok, %{status: "ok", result: inspect(other)}}

  defp fetch_handler_module(handler) do
    module_name = "Elixir." <> handler

    try do
      module = String.to_existing_atom(module_name)

      if function_exported?(module, :call_tool, 2),
        do: {:ok, module},
        else: {:error, "Module does not export call_tool/2"}
    rescue
      ArgumentError -> {:error, "Module is not loaded"}
    end
  end

  defp normalize_auth_context(context) do
    credential_org = context[:credential_org] || context["credential_org"]
    resource_org = context[:resource_org] || context["resource_org"] || credential_org
    role = context[:role] || context["role"]

    if valid_org?(credential_org) and valid_org?(resource_org) and is_binary(role) and role != "" do
      {:ok,
       %{
         credential_org: credential_org,
         resource_org: resource_org,
         role: role,
         permissions: context[:permissions] || context["permissions"] || [],
         allowed_teams: context[:allowed_teams] || context["allowed_teams"],
         allowed_projects: context[:allowed_projects] || context["allowed_projects"],
         agent_id: context[:agent_id] || context["agent_id"],
         attribution_id: context[:attribution_id] || context["attribution_id"],
         audience: context[:audience] || context["audience"],
         audience_source: context[:audience_source] || context["audience_source"],
         client_name: context[:client_name] || context["client_name"],
         working_repo: context[:working_repo] || context["working_repo"],
         workspace_id: context[:workspace_id] || context["workspace_id"],
         mcp_endpoint: context[:mcp_endpoint] || context["mcp_endpoint"]
       }}
    else
      {:error, "Missing authentication context"}
    end
  end

  defp inject_auth_context(args, auth) do
    args
    |> Enum.reject(fn {key, _value} ->
      (is_binary(key) or is_atom(key)) and String.starts_with?(to_string(key), "_auth_")
    end)
    |> Map.new()
    |> Map.merge(%{
      "_auth_role" => auth.role,
      "_auth_org_id" => auth.resource_org,
      "_auth_credential_org_id" => auth.credential_org,
      "_auth_permissions" => auth.permissions,
      "_auth_allowed_teams" => auth.allowed_teams,
      "_auth_allowed_projects" => auth.allowed_projects,
      "_auth_agent_id" => auth.agent_id,
      "_auth_attribution" => auth.attribution_id,
      "_auth_authority_level" => auth[:authority_level] || Process.get(:acs_mcp_authority_level),
      "_auth_authority_sort_order" =>
        auth[:authority_sort_order] || Process.get(:acs_mcp_authority_sort_order),
      "_auth_audience" => auth[:audience] && to_string(auth[:audience]),
      "_auth_audience_source" =>
        case auth[:audience_source] do
          nil -> nil
          src when is_atom(src) -> Atom.to_string(src)
          src -> to_string(src)
        end,
      "_auth_client_name" => auth[:client_name],
      "_auth_repo" => auth[:working_repo],
      "_auth_workspace_id" => auth[:workspace_id],
      "_auth_mcp_endpoint" => auth[:mcp_endpoint]
    })
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp filter_category(tools, nil), do: tools

  defp filter_category(tools, category),
    do: Enum.filter(tools, &((&1["category"] || "uncategorized") == category))

  defp valid_org?(org), do: is_binary(org) and org != ""

  defp snapshot_tool_count(snapshot),
    do:
      map_size(snapshot.shared.tools) +
        Enum.reduce(snapshot.tenants, 0, fn {_org, scope}, total ->
          total + map_size(scope.tools)
        end)

  defp maybe_log_operation(name, result, latency_ms, args, opts) do
    Acs.Observability.AgentOps.log_tool(
      tool_name: name,
      result: result,
      latency_ms: latency_ms,
      agent_id: args["agent_id"] || args["_auth_agent_id"],
      org: args["_auth_org_id"],
      audience: args["_auth_audience"],
      audience_source: args["_auth_audience_source"],
      client_name: args["_auth_client_name"],
      mcp_endpoint: args["_auth_mcp_endpoint"],
      role: args["_auth_role"],
      execution_id: args["execution_id"],
      task_id: args["task_id"],
      scope_path: scope_from_args(args),
      kind: args["kind"] || args["document_type"],
      discovery: Keyword.get(opts, :discovery, false),
      args: args
    )

    :ok
  end

  @doc "Tracks attempts to invoke unknown tools for agent-ops discovery."
  def track_tool_discovery(tool_name, args) when is_map(args) do
    Acs.Observability.AgentOps.log_tool(
      tool_name: tool_name,
      result: {:error, "Unknown tool: #{tool_name}"},
      latency_ms: nil,
      agent_id: args["agent_id"] || args["_auth_agent_id"],
      org: args["_auth_org_id"],
      audience: args["_auth_audience"],
      audience_source: args["_auth_audience_source"],
      client_name: args["_auth_client_name"],
      mcp_endpoint: args["_auth_mcp_endpoint"],
      role: args["_auth_role"],
      execution_id: args["execution_id"],
      task_id: args["task_id"],
      scope_path: scope_from_args(args),
      kind: args["kind"] || args["document_type"],
      discovery: true
    )

    :ok
  end

  def track_tool_discovery(tool_name, agent_id, execution_id) do
    track_tool_discovery(tool_name, %{
      "agent_id" => agent_id,
      "execution_id" => execution_id
    })
  end

  defp scope_from_args(args) do
    cond do
      is_binary(args["scope_path"]) and args["scope_path"] != "" ->
        args["scope_path"]

      is_binary(args["scope"]) and args["scope"] != "" ->
        args["scope"]

      is_list(args["scope_paths"]) ->
        Enum.find_value(args["scope_paths"], fn
          s when is_binary(s) and s != "" -> s
          _ -> nil
        end)

      true ->
        nil
    end
  end

  defp safe_execute(fun) do
    fun.()
  rescue
    error ->
      Logger.error("ToolRegistry tool crash: #{Exception.message(error)}")
      {:error, "Tool execution failed"}
  catch
    :exit, reason ->
      Logger.error("ToolRegistry tool exit: #{inspect(reason)}")
      {:error, "Tool execution failed"}
  end
end

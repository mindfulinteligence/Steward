defmodule Acs.MCP.CoreToolRoles do
  @moduledoc """
  Role assignments for built-in tools dispatched via `Acs.MCP.Tools`.

  YAML-loaded tools use their own `roles` field. Core tools fall back to this
  map so `ToolRegistry.authorize_tool/3` enforces the same RBAC model.

  ## Chat surface

  Chat assistants (Claude.ai / ChatGPT connectors) get exactly three tools via
  `chat_surface/0` (`steward_ask`, `steward_write`, `steward_work`). Keep that
  list in sync with `priv/prompts/chat_system_prompt_body.md` and chat guidance.

  All three are marked `_meta["anthropic/alwaysLoad"]` via `eager_priority/0` —
  chat does not rely on Tool Search.
  """

  @admin_only ~w(
    query
    config_lookup
    connection_diagnostic
    memory_health_check
    get_logs
    list_orgs
    app_configure
    app_remove
    write_tool
    ack_error_trace
    resolve_error_trace
    create_task_from_error_trace
    generate_developer_key
    list_developer_keys
    revoke_developer_key
    create_org
    upsert_authority_level
    delete_authority_level
    set_member_authority_level
    specs_approve
    specs_reject
    skill_audit_status
  )

  @admin_collaborator ~w(
    steward_ask
    steward_write
    steward_work
    get_started
    claim_work
    release_work
    close_work
    create_work
    lock_file
    unlock_file
    get_present_status
    get_locked_files
    list_tasks
    resolve_user_task
    submit_task_feedback
    help
    save_memory
    query_memories
    set_memory_status
    get_person_status
    set_person_status
    list_authority_levels
    generate_guidance_packet
    ask
    specs_get
    query_specs
    specs_propose
    documents_propose
    skill_get
    skill_save
    list_error_traces
    list_plugins
    app_list
  )

  # Consolidated chat-only façade. Fine-grained names remain available to coding
  # clients and are accepted as non-advertised chat aliases for one release.
  @chat_surface ~w(
    steward_ask
    steward_write
    steward_work
  )

  @chat_only @chat_surface

  # The complete chat surface is always loaded; chat does not use Tool Search.
  @eager_priority ~w(
    steward_ask
    steward_write
    steward_work
  )

  @admin_service ~w(time)

  @roles Map.new(@admin_only, &{&1, ["admin"]})
         |> Map.merge(Map.new(@admin_collaborator, &{&1, ["admin", "collaborator"]}))
         |> Map.merge(Map.new(@admin_service, &{&1, ["admin", "service", "collaborator"]}))

  @default_roles ["admin"]

  @doc "Tools exposed to chat-audience MCP sessions (Claude.ai / ChatGPT)."
  @spec chat_surface() :: [String.t()]
  def chat_surface, do: @chat_surface

  @doc "Returns true when `name` is on the chat connector surface."
  @spec chat_tool?(String.t()) :: boolean()
  def chat_tool?(name) when is_binary(name), do: name in @chat_surface
  def chat_tool?(_), do: false

  @doc """
  Tools that must stay in the model context under Anthropic Tool Search.

  Chat marks the entire `chat_surface/0` always-loaded. Emits
  `_meta["anthropic/alwaysLoad"]`.
  """
  @spec eager_tool?(String.t()) :: boolean()
  def eager_tool?(name) when is_binary(name), do: name in @eager_priority
  def eager_tool?(_), do: false

  @doc "Priority order for alwaysLoad tools (chat façade)."
  @spec eager_priority() :: [String.t()]
  def eager_priority, do: @eager_priority

  @doc "Sort key so eager chat tools lead tools/list."
  @spec list_sort_key(map()) :: {integer(), integer() | String.t()}
  def list_sort_key(%{"name" => name}) do
    case Enum.find_index(@eager_priority, &(&1 == name)) do
      nil -> {1, name}
      idx -> {0, idx}
    end
  end

  def list_sort_key(_), do: {1, ""}

  @doc "Attach Anthropic alwaysLoad `_meta` for chat façade tools."
  @spec with_eager_meta(map()) :: map()
  def with_eager_meta(%{"name" => name} = tool) do
    if eager_tool?(name) do
      Map.put(tool, "_meta", %{"anthropic/alwaysLoad" => true})
    else
      tool
    end
  end

  def with_eager_meta(tool), do: tool

  @doc "Returns the roles allowed to call a core tool."
  @spec roles_for(String.t()) :: [String.t()]
  def roles_for(name) when is_binary(name), do: Map.get(@roles, name, @default_roles)

  @doc "Returns true when `role` may invoke the core tool (ignores audience)."
  @spec authorized?(String.t(), String.t()) :: boolean()
  def authorized?(name, role) when is_binary(name) and is_binary(role) do
    role in roles_for(name)
  end

  def authorized?(_, _), do: false

  @doc """
  Authorize with optional audience.

  When `audience` is `:chat`, the tool must also be on `chat_surface/0`.
  """
  @spec authorized?(String.t(), String.t(), atom() | String.t() | nil) :: boolean()
  def authorized?(name, role, audience) when is_binary(name) and is_binary(role) do
    authorized?(name, role) and audience_allows?(name, audience)
  end

  def authorized?(_, _, _), do: false

  defp audience_allows?(_name, nil), do: true

  defp audience_allows?(name, audience) when audience in [:coding, "coding", :mcp, "mcp"],
    do: name not in @chat_only

  defp audience_allows?(name, audience) when audience in [:chat, "chat", :knowledge, "knowledge"],
    do: chat_tool?(name)

  defp audience_allows?(_name, _audience), do: true
end

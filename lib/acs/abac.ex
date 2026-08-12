defmodule Acs.Abac do
  @moduledoc """
  Attribute-based access control for org knowledge and coding-agent documents.

  ## Use cases

  1. **Coding agents** — specs (`Acs.Specs.Entry`) scoped by team/project
     so agents only read and write specs for code they work on.

  2. **Org KB memories** — atomic knowledge scoped by team/project/visibility for
     organizational knowledge about specific teams or projects.

  ## Visibility model

  Access is limited by **sensitivity**, **Steward role** (review on write), and
  **data authority clearance** (read). Clearance applies to every MCP principal
  (OAuth users and API keys), including org admin — role does not bypass rank.

  - `org`, `team`, `project` — labels describing where knowledge belongs.
  - `personal` — visible only to the creator (`created_by.id` / `created_by_agent`).
  - Ranked memories (`authority_sort_order`) — stamped from the **writer's**
    clearance; readable when the viewer's order V satisfies `M >= V`.
    Unranked memories are not gated.

  Restricted roles may write any non-personal scope; those writes land as
  `proposed` (see `memory_status_for_write/2`).

  ponytail: `allowed_teams` / `allowed_projects` remain on the context for later
  re-enable; they are not enforced while team membership has no source of truth.
  """

  @restricted_roles ~w(collaborator reader)
  @valid_visibilities ~w(org team project personal)

  defstruct agent_role: nil,
            allowed_teams: [],
            allowed_projects: [],
            agent_id: nil,
            authority_level_slug: nil,
            authority_sort_order: nil

  @type t :: %__MODULE__{
          agent_role: String.t() | nil,
          allowed_teams: [String.t()],
          allowed_projects: [String.t()],
          agent_id: String.t() | nil,
          authority_level_slug: String.t() | nil,
          authority_sort_order: integer() | nil
        }

  @doc "Build ABAC context from MCP tool args (injected by Protocol)."
  def from_args(args) when is_map(args) do
    %__MODULE__{
      agent_role: Map.get(args, "_auth_role"),
      allowed_teams: normalize_list(Map.get(args, "_auth_allowed_teams")),
      allowed_projects: normalize_list(Map.get(args, "_auth_allowed_projects")),
      agent_id: Map.get(args, "_auth_agent_id"),
      authority_level_slug: Map.get(args, "_auth_authority_level"),
      authority_sort_order: Map.get(args, "_auth_authority_sort_order")
    }
  end

  @doc "Build ABAC context from keyword opts (Indexer, Guidance, etc.)."
  def from_keyword(opts) when is_list(opts) do
    %__MODULE__{
      agent_role: Keyword.get(opts, :agent_role),
      allowed_teams: normalize_list(Keyword.get(opts, :allowed_teams)),
      allowed_projects: normalize_list(Keyword.get(opts, :allowed_projects)),
      agent_id: Keyword.get(opts, :agent_id),
      authority_level_slug: Keyword.get(opts, :authority_level_slug),
      authority_sort_order: Keyword.get(opts, :authority_sort_order)
    }
  end

  @doc "Returns true when the item is readable under the given context."
  def visible?(%__MODULE__{} = ctx, item), do: visible_item?(item, ctx)

  @doc "Filters a list to items visible under the given context."
  def filter(items, %__MODULE__{} = ctx) when is_list(items) do
    Enum.filter(items, &visible_item?(&1, ctx))
  end

  @doc """
  Returns true when the item is editable under the given context.

  Admin/owner may edit anything. Everyone else may only edit items stamped at
  a rank strictly below their own clearance (`AuthorityLevels.can_edit?/2`).
  Personal items remain editable only by their creator.
  """
  def can_edit?(%__MODULE__{agent_role: role} = _ctx, _item)
      when role in ~w(admin owner),
      do: true

  def can_edit?(%__MODULE__{} = ctx, item) do
    visibility = field(item, "visibility", "org")

    cond do
      visibility == "personal" ->
        personal_owner?(ctx, item)

      true ->
        Acs.AuthorityLevels.can_edit?(
          resolved_viewer_order(ctx),
          field(item, "authority_sort_order")
        )
    end
  end

  @doc """
  Returns true when the viewer is the creator of the item.

  The creator may always retire (stale/deprecate) their own memories regardless
  of rank — used by `set_memory_status` on top of `can_edit?/2`.
  """
  def creator?(%__MODULE__{} = ctx, item) do
    case {agent_id(ctx), creator_id(item)} do
      {viewer, creator} when is_binary(viewer) and viewer != "" and is_binary(creator) ->
        viewer == creator

      _ ->
        false
    end
  end

  defp agent_id(%__MODULE__{agent_id: agent_id}), do: agent_id

  @doc """
  Validates write attributes (`visibility`, `team`, `project`).

  Checks shape only — every role may write every scope. Authority is applied by
  `memory_status_for_write/2`, which routes restricted roles through review.

  Returns `:ok` or `{:error, reason}`.
  """
  def validate_write(%__MODULE__{} = _ctx, attrs) when is_map(attrs) do
    visibility = field(attrs, "visibility", "org")
    team = field(attrs, "team")
    project = field(attrs, "project")

    with :ok <- validate_visibility_value(visibility) do
      validate_scope_fields(visibility, team, project)
    end
  end

  @doc """
  For restricted roles, force `proposed` status so shared knowledge is reviewed
  before becoming searchable as approved. Applies to every shared scope — `org`,
  `team`, and `project` alike — so team visibility cannot be used to skip review.
  Personal memories skip review — they are only visible to the creator.
  """
  def memory_status_for_write(%__MODULE__{} = ctx, attrs) when is_map(attrs) do
    cond do
      field(attrs, "visibility", "org") == "personal" -> nil
      restricted_role?(ctx) -> "proposed"
      true -> nil
    end
  end

  defp restricted_role?(%__MODULE__{agent_role: role}) when role in @restricted_roles, do: true
  defp restricted_role?(_), do: false

  defp visible_item?(item, ctx) do
    visibility = field(item, "visibility", "org")

    cond do
      visibility == "personal" ->
        personal_owner?(ctx, item)

      true ->
        order = resolved_viewer_order(ctx)

        Acs.AuthorityLevels.can_read?(
          order,
          field(item, "authority_sort_order")
        )
    end
  end

  defp resolved_viewer_order(%__MODULE__{authority_sort_order: order})
       when is_integer(order),
       do: order

  defp resolved_viewer_order(%__MODULE__{authority_level_slug: slug})
       when is_binary(slug) and slug != "" do
    Acs.AuthorityLevels.viewer_sort_order(Acs.Org.current(), slug)
  end

  # Missing clearance → cannot read ranked memories (can_read?(nil, ranked) is false).
  defp resolved_viewer_order(_), do: nil

  defp personal_owner?(%__MODULE__{agent_id: agent_id}, item)
       when is_binary(agent_id) and agent_id != "" do
    creator_id(item) == agent_id
  end

  defp personal_owner?(_, _), do: false

  defp creator_id(item) do
    case field(item, "created_by_agent") do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        case field(item, "created_by") do
          %{"id" => id} when is_binary(id) -> id
          %{id: id} when is_binary(id) -> id
          _ -> nil
        end
    end
  end

  defp validate_visibility_value(visibility) when visibility in @valid_visibilities, do: :ok

  defp validate_visibility_value(visibility),
    do:
      {:error, "Invalid visibility '#{visibility}'. Must be one of: org, team, project, personal"}

  defp validate_scope_fields("team", team, _project) when is_binary(team) and team != "",
    do: :ok

  defp validate_scope_fields("team", _team, _project),
    do: {:error, "team visibility requires a non-empty team"}

  defp validate_scope_fields("project", _team, project) when is_binary(project) and project != "",
    do: :ok

  defp validate_scope_fields("project", _team, _project),
    do: {:error, "project visibility requires a non-empty project"}

  defp validate_scope_fields(_visibility, _team, _project), do: :ok

  defp field(item, key, default \\ nil)

  defp field(%_{} = struct, key, default) do
    atom_key = String.to_existing_atom(key)
    Map.get(struct, atom_key, default)
  rescue
    ArgumentError -> default
  end

  defp field(item, key, default) when is_map(item) do
    Map.get(item, key) || Map.get(item, String.to_existing_atom(key)) || default
  rescue
    ArgumentError -> Map.get(item, key, default)
  end

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(_), do: []
end

defmodule Acs.AuthorityLevels do
  @moduledoc """
  Org-defined data authority levels (clearance for memory reads).

  Levels are ordered by `sort_order` where **1 is highest**. A viewer with
  sort order V may read memories stamped with order M when `M >= V` (same level
  or lower). Unranked memories (`authority_sort_order` nil) are not gated.

  New memories are stamped from the **writer's** clearance (not the about-person).

  Default seed:

  - 1 / high / Executive
  - 2 / elevated / Senior
  - 3 / standard / Standard
  """

  import Ecto.Query

  alias Acs.Accounts.{OrganizationInvitation, User}
  alias Acs.AuthorityLevel
  alias Acs.Developers.DeveloperApiKey
  alias Acs.Memory.Schema, as: MemorySchema
  alias Acs.Orgs.Organization
  alias Acs.PersonStatus
  alias Acs.Repo

  @max_levels 20
  @min_levels 1

  # Clearance so low only unranked memories pass, used when no org context exists.
  @no_clearance_order 2_147_483_647

  @defaults [
    %{slug: "high", label: "Executive", sort_order: 1},
    %{slug: "elevated", label: "Senior", sort_order: 2},
    %{slug: "standard", label: "Standard", sort_order: 3}
  ]

  def max_levels, do: @max_levels
  def defaults, do: @defaults

  @doc "Ensure default levels exist for `org`, then return them ordered by sort_order."
  def list(org) when is_binary(org) do
    org = normalize_org(org)
    ensure_defaults!(org)

    Repo.all(
      from l in AuthorityLevel,
        where: l.org == ^org,
        order_by: [asc: l.sort_order]
    )
  end

  def get_by_slug(org, slug) when is_binary(org) and is_binary(slug) do
    org = normalize_org(org)
    slug = AuthorityLevel.slugify(slug)
    ensure_defaults!(org)
    Repo.get_by(AuthorityLevel, org: org, slug: slug)
  end

  @doc "Resolve slug or exact label (case-insensitive) to a level."
  def resolve(org, slug_or_label) when is_binary(org) and is_binary(slug_or_label) do
    org = normalize_org(org)
    ensure_defaults!(org)
    key = String.trim(slug_or_label)
    slug = AuthorityLevel.slugify(key)

    levels = list(org)

    Enum.find(levels, &(&1.slug == slug)) ||
      Enum.find(levels, fn l -> String.downcase(l.label) == String.downcase(key) end)
  end

  def resolve(_org, _), do: nil

  def sort_order_for(org, slug) when is_binary(org) and is_binary(slug) do
    case get_by_slug(org, slug) do
      %AuthorityLevel{sort_order: order} -> order
      nil -> nil
    end
  end

  def sort_order_for(_, _), do: nil

  @doc "Lowest clearance (highest sort_order number) for the org."
  def lowest(org) when is_binary(org) do
    list(org) |> List.last()
  end

  @doc """
  Viewer clearance sort order. Nil/unknown slug → lowest level; unknown org → no clearance.
  Returns integer.
  """
  def viewer_sort_order(org, slug) when is_binary(org) and is_binary(slug) and slug != "" do
    case get_by_slug(org, slug) do
      %AuthorityLevel{sort_order: order} -> order
      nil -> lowest_sort_order(org)
    end
  end

  def viewer_sort_order(org, _slug) when is_binary(org), do: lowest_sort_order(org)

  # No resolvable org (e.g. cross-org scan) → deny every stamped memory rather than crash.
  def viewer_sort_order(_org, _slug), do: @no_clearance_order

  defp lowest_sort_order(org) do
    case lowest(org) do
      %AuthorityLevel{sort_order: order} -> order
      _ -> @no_clearance_order
    end
  end

  @doc "True when viewer may read a memory with the given stamped order (or nil = ungated)."
  def can_read?(nil, nil), do: true
  def can_read?(nil, memory_order) when is_integer(memory_order), do: false
  def can_read?(viewer_order, nil) when is_integer(viewer_order), do: true

  def can_read?(viewer_order, memory_order)
      when is_integer(viewer_order) and is_integer(memory_order) do
    memory_order >= viewer_order
  end

  def can_read?(_, _), do: false

  @doc """
  True when a viewer may EDIT a memory/spec/skill with the given stamped order.

  Editing is stricter than reading: a viewer may only edit items stamped at a
  rank strictly below their own (`memory_order > viewer_order`, since 1 is
  highest) — except the top rank (sort_order 1), which may also edit items at
  its own level. Unranked items (nil) follow the same fallbacks as `can_read?/2`
  for backwards compatibility. Admin/owner bypass lives at the call sites.
  """
  def can_edit?(nil, nil), do: true
  def can_edit?(nil, item_order) when is_integer(item_order), do: false
  def can_edit?(viewer_order, nil) when is_integer(viewer_order), do: true

  def can_edit?(viewer_order, item_order)
      when is_integer(viewer_order) and is_integer(item_order) do
    item_order > viewer_order or viewer_order == 1
  end

  def can_edit?(_, _), do: false

  def upsert(org, attrs) when is_binary(org) and is_map(attrs) do
    org = normalize_org(org)
    ensure_defaults!(org)

    slug =
      case attrs["slug"] || attrs[:slug] do
        s when is_binary(s) and s != "" -> AuthorityLevel.slugify(s)
        _ -> AuthorityLevel.slugify(attrs["label"] || attrs[:label] || "")
      end

    existing = Repo.get_by(AuthorityLevel, org: org, slug: slug)
    count = count(org)

    cond do
      is_nil(existing) and count >= @max_levels ->
        {:error, "Organizations may have at most #{@max_levels} authority levels"}

      true ->
        base = existing || %AuthorityLevel{org: org}

        params = %{
          "org" => org,
          "slug" => slug,
          "label" => attrs["label"] || attrs[:label] || (existing && existing.label) || slug,
          "sort_order" =>
            parse_order(attrs["sort_order"] || attrs[:sort_order]) ||
              (existing && existing.sort_order) || next_sort_order(org)
        }

        base
        |> AuthorityLevel.changeset(params)
        |> Repo.insert_or_update()
    end
  end

  @doc """
  Delete a level. When anyone still uses the slug, pass `remap: :promote | :demote | slug`.

  - `:promote` — nearest remaining higher clearance (lower sort_order)
  - `:demote` — nearest remaining lower clearance (higher sort_order)
  - binary slug — remap to that remaining level

  Returns `{:error, :remap_required, info}` when remap is needed but missing.
  """
  def delete(org, slug, opts \\ [])

  def delete(org, slug, opts) when is_binary(org) and is_binary(slug) and is_list(opts) do
    org = normalize_org(org)
    slug = AuthorityLevel.slugify(slug)
    remap = Keyword.get(opts, :remap) || Keyword.get(opts, :remap_to)

    case Repo.get_by(AuthorityLevel, org: org, slug: slug) do
      nil ->
        {:error, :not_found}

      level ->
        if count(org) <= @min_levels do
          {:error, "Organizations must keep at least #{@min_levels} authority level"}
        else
          info = usage_summary(org, level)

          cond do
            info.total == 0 ->
              Repo.delete(level)

            is_nil(remap) or remap in ["", false] ->
              {:error, :remap_required, remap_required_payload(org, level, info)}

            true ->
              with {:ok, target} <- resolve_remap_level(org, level, remap) do
                Repo.transaction(fn ->
                  remapped = apply_remap!(org, level, target)
                  {:ok, deleted} = Repo.delete(level)
                  %{deleted: deleted, remapped_to: to_map(target), remapped: remapped}
                end)
                |> case do
                  {:ok, result} -> {:ok, result}
                  {:error, reason} -> {:error, reason}
                end
              end
          end
        end
    end
  end

  def ensure_defaults!(org) when is_binary(org) do
    org = normalize_org(org)

    if count(org) == 0 do
      Enum.each(@defaults, fn attrs ->
        %AuthorityLevel{}
        |> AuthorityLevel.changeset(Map.put(attrs, :org, org))
        |> Repo.insert!()
      end)
    end

    :ok
  end

  def to_map(%AuthorityLevel{} = level) do
    %{
      org: level.org,
      slug: level.slug,
      label: level.label,
      sort_order: level.sort_order
    }
  end

  def count(org) when is_binary(org) do
    org = normalize_org(org)

    Repo.one(
      from l in AuthorityLevel,
        where: l.org == ^org,
        select: count(l.id)
    ) || 0
  end

  defp next_sort_order(org) do
    case list(org) |> List.last() do
      %AuthorityLevel{sort_order: n} -> n + 1
      nil -> 1
    end
  end

  defp parse_order(n) when is_integer(n), do: n

  defp parse_order(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_order(_), do: nil

  defp normalize_org(org) when is_binary(org), do: org |> String.trim() |> String.downcase()

  defp usage_summary(org, %AuthorityLevel{} = level) do
    org_id = organization_id(org)

    users =
      if org_id do
        Repo.one(
          from u in User,
            where: u.organization_id == ^org_id and u.authority_level_slug == ^level.slug,
            select: count(u.id)
        ) || 0
      else
        0
      end

    invitations =
      if org_id do
        Repo.one(
          from i in OrganizationInvitation,
            where: i.organization_id == ^org_id and i.authority_level_slug == ^level.slug,
            select: count(i.id)
        ) || 0
      else
        0
      end

    persons =
      Repo.one(
        from p in PersonStatus,
          where: p.org == ^org and p.rank == ^level.slug,
          select: count(p.id)
      ) || 0

    keys =
      Repo.one(
        from k in DeveloperApiKey,
          where: k.org == ^org and k.authority_level_slug == ^level.slug,
          select: count(k.id)
      ) || 0

    memories =
      Repo.one(
        from m in MemorySchema,
          where: m.org == ^org and m.authority_sort_order == ^level.sort_order,
          select: count(m.id)
      ) || 0

    %{
      users: users,
      invitations: invitations,
      persons: persons,
      developer_keys: keys,
      memories: memories,
      total: users + invitations + persons + keys + memories
    }
  end

  defp remap_required_payload(org, level, info) do
    remaining = list(org) |> Enum.reject(&(&1.slug == level.slug))
    promote = neighbor(remaining, level, :promote)
    demote = neighbor(remaining, level, :demote)

    %{
      slug: level.slug,
      label: level.label,
      affected: info,
      promote_to: promote && to_map(promote),
      demote_to: demote && to_map(demote),
      message:
        "Level '#{level.label}' is in use (#{info.total} records). Pass remap: \"promote\", \"demote\", or a remaining level slug."
    }
  end

  defp resolve_remap_level(org, deleted, :promote),
    do: resolve_remap_level(org, deleted, "promote")

  defp resolve_remap_level(org, deleted, :demote),
    do: resolve_remap_level(org, deleted, "demote")

  defp resolve_remap_level(org, deleted, remap) when is_binary(remap) do
    remaining = list(org) |> Enum.reject(&(&1.slug == deleted.slug))
    key = String.trim(remap) |> String.downcase()

    cond do
      key in ["promote", "up"] ->
        case neighbor(remaining, deleted, :promote) do
          nil -> {:error, "No higher authority level remains to promote into"}
          level -> {:ok, level}
        end

      key in ["demote", "down"] ->
        case neighbor(remaining, deleted, :demote) do
          nil -> {:error, "No lower authority level remains to demote into"}
          level -> {:ok, level}
        end

      true ->
        case Enum.find(remaining, &(&1.slug == AuthorityLevel.slugify(key))) ||
               Enum.find(remaining, &(String.downcase(&1.label) == key)) do
          nil -> {:error, "Remap target '#{remap}' is not a remaining authority level"}
          level -> {:ok, level}
        end
    end
  end

  defp resolve_remap_level(_, _, _),
    do: {:error, "remap must be promote, demote, or a level slug"}

  # Nearest higher privilege = largest sort_order still below deleted.
  defp neighbor(levels, deleted, :promote) do
    levels
    |> Enum.filter(&(&1.sort_order < deleted.sort_order))
    |> Enum.sort_by(& &1.sort_order, :desc)
    |> List.first()
  end

  # Nearest lower privilege = smallest sort_order still above deleted.
  defp neighbor(levels, deleted, :demote) do
    levels
    |> Enum.filter(&(&1.sort_order > deleted.sort_order))
    |> Enum.sort_by(& &1.sort_order, :asc)
    |> List.first()
  end

  defp apply_remap!(org, %AuthorityLevel{} = from, %AuthorityLevel{} = to) do
    org_id = organization_id(org)

    users =
      if org_id do
        {n, _} =
          Repo.update_all(
            from(u in User,
              where: u.organization_id == ^org_id and u.authority_level_slug == ^from.slug
            ),
            set: [authority_level_slug: to.slug]
          )

        n
      else
        0
      end

    invitations =
      if org_id do
        {n, _} =
          Repo.update_all(
            from(i in OrganizationInvitation,
              where: i.organization_id == ^org_id and i.authority_level_slug == ^from.slug
            ),
            set: [authority_level_slug: to.slug]
          )

        n
      else
        0
      end

    {persons, _} =
      Repo.update_all(
        from(p in PersonStatus, where: p.org == ^org and p.rank == ^from.slug),
        set: [rank: to.slug]
      )

    {keys, _} =
      Repo.update_all(
        from(k in DeveloperApiKey,
          where: k.org == ^org and k.authority_level_slug == ^from.slug
        ),
        set: [authority_level_slug: to.slug]
      )

    {memories, _} =
      Repo.update_all(
        from(m in MemorySchema,
          where: m.org == ^org and m.authority_sort_order == ^from.sort_order
        ),
        set: [authority_sort_order: to.sort_order]
      )

    %{
      users: users,
      invitations: invitations,
      persons: persons,
      developer_keys: keys,
      memories: memories
    }
  end

  defp organization_id(org_slug) do
    case Repo.get_by(Organization, slug: org_slug) do
      %{id: id} -> id
      _ -> nil
    end
  end
end

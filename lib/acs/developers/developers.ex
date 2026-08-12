defmodule Acs.Developers do
  @moduledoc """
  Context for managing developer API keys.

  Keys are stored as SHA-256 hashes for fast lookup.
  Raw keys are shown once at creation time and cannot be retrieved.
  """
  alias Acs.Developers.DeveloperApiKey
  alias Acs.Repo
  import Ecto.Query
  require Logger

  @doc """
  Authenticate a developer by raw key.
  Returns `{:ok, %{role: role, org: org}}` or `{:error, reason}`.
  """
  def authenticate(key) do
    hash = hash_key(key)

    case Repo.get_by(DeveloperApiKey, key_hash: hash, active: true) do
      nil ->
        {:error, "Invalid API key"}

      dev_key ->
        Repo.update_all(
          from(d in DeveloperApiKey, where: d.id == ^dev_key.id),
          set: [last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

        {:ok,
         %{
           role: dev_key.role,
           org: dev_key.org,
           kind: dev_key.kind || "code",
           developer_name: dev_key.developer_name,
           authority_level_slug: dev_key.authority_level_slug || "standard",
           allowed_teams: decode_json(dev_key.allowed_teams_json),
           allowed_projects: decode_json(dev_key.allowed_projects_json)
         }}
    end
  end

  @doc """
  Generate a new developer API key.

  Returns `{:ok, %{key: raw_key, developer: dev}}`.
  The raw key is shown once and cannot be retrieved later.

  Key format: `acs_dev_<64-char-hex-random>`
  """
  def generate_key(name, opts \\ []) do
    role = Keyword.get(opts, :role, "collaborator")
    org = Keyword.get(opts, :org) || Keyword.get(opts, :cluster, "default")
    authority_level_slug = Keyword.get(opts, :authority_level_slug, "standard")
    kind = Keyword.get(opts, :kind, "code")
    allowed_teams = Keyword.get(opts, :allowed_teams)
    allowed_projects = Keyword.get(opts, :allowed_projects)

    raw_key = generate_raw_key()
    hash = hash_key(raw_key)
    prefix = String.slice(raw_key, 0, 12)

    case %DeveloperApiKey{}
         |> DeveloperApiKey.changeset(%{
           key_hash: hash,
           key_prefix: prefix,
           developer_name: name,
           role: role,
           org: org,
           authority_level_slug: authority_level_slug,
           kind: kind,
           active: true,
           allowed_teams_json: encode_json(allowed_teams),
           allowed_projects_json: encode_json(allowed_projects)
         })
         |> Repo.insert() do
      {:ok, dev} ->
        {:ok, %{key: raw_key, developer: dev}}

      {:error, changeset} ->
        {:error, "Failed to create developer key: #{inspect(changeset.errors)}"}
    end
  end

  @doc """
  Get a developer by id.
  """
  def get_developer(id, org \\ Acs.Org.current()) do
    Repo.get_by(DeveloperApiKey, id: id, org: org)
  end

  @doc """
  Update a developer's attributes (name, role, org, allowed_teams, allowed_projects).
  Cannot change key_hash or key_prefix.
  """
  def update_developer(id, attrs, org \\ Acs.Org.current()) do
    case Repo.get_by(DeveloperApiKey, id: id, org: org) do
      nil ->
        {:error, :not_found}

      dev ->
        attrs =
          attrs
          |> Map.drop([:key_hash, :key_prefix])
          |> maybe_encode_json(:allowed_teams)
          |> maybe_encode_json(:allowed_projects)

        dev
        |> DeveloperApiKey.changeset(attrs)
        |> Repo.update()
    end
  end

  defp maybe_encode_json(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, list} when is_list(list) -> Map.put(attrs, :"#{field}_json", encode_json(list))
      {:ok, nil} -> Map.put(attrs, :"#{field}_json", nil)
      _ -> attrs
    end
  end

  @doc """
  List all developers.
  """
  def list_developers(org \\ Acs.Org.current()) do
    Repo.all(from d in DeveloperApiKey, where: d.org == ^org)
  end

  @doc """
  Revoke a developer's key by setting active to false.
  """
  def revoke(id, org \\ Acs.Org.current()) do
    case Repo.get_by(DeveloperApiKey, id: id, org: org) do
      nil ->
        {:error, :not_found}

      dev ->
        dev
        |> Ecto.Changeset.change(%{active: false})
        |> Repo.update()
    end
  end

  @doc """
  Revoke a developer's key by developer_name (public identifier, no DB id needed).

  developer_name is not unique — a developer may have multiple keys — so all
  matching active keys are revoked.
  """
  def revoke_by_name(developer_name, org \\ Acs.Org.current()) do
    query =
      from(d in DeveloperApiKey,
        where: d.developer_name == ^developer_name and d.org == ^org and d.active == true
      )

    case Repo.all(query) do
      [] ->
        {:error, :not_found}

      devs ->
        {_count, _} =
          Repo.update_all(query, set: [active: false, updated_at: DateTime.utc_now()])

        {:ok, %{List.first(devs) | active: false, updated_at: DateTime.utc_now()}}
    end
  end

  @doc """
  Hash a raw key using SHA-256.
  Returns hex-encoded digest.
  """
  def hash_key(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  @key_prefix "acs_dev_"

  defp generate_raw_key do
    @key_prefix <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end

  defp encode_json(nil), do: nil
  defp encode_json(list) when is_list(list), do: Jason.encode!(list)

  defp decode_json(nil), do: nil

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> nil
    end
  end
end

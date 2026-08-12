defmodule Acs.Developers.DeveloperApiKey do
  @moduledoc """
  Ecto schema for developer API keys with SHA-256 hashing.

  Keys are stored as SHA-256 hex digests for fast lookup.
  The raw key is shown once at creation time and cannot be retrieved.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "acs_developer_api_keys" do
    field :key_hash, :string
    field :key_prefix, :string
    field :developer_name, :string
    field :role, :string, default: "collaborator"
    field :org, :string, default: "default"
    field :authority_level_slug, :string, default: "standard"
    field :kind, :string, default: "code"
    field :active, :boolean, default: true
    field :last_used_at, :utc_datetime
    field :allowed_teams_json, :string
    field :allowed_projects_json, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [
      :key_hash,
      :key_prefix,
      :developer_name,
      :role,
      :org,
      :authority_level_slug,
      :kind,
      :active,
      :last_used_at,
      :allowed_teams_json,
      :allowed_projects_json
    ])
    |> validate_required([:key_hash, :developer_name])
    |> validate_inclusion(:role, ~w(admin service reader collaborator))
    |> validate_inclusion(:kind, ~w(code chat))
    |> validate_length(:developer_name, min: 1, max: 100)
  end
end

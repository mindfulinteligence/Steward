defmodule Acs.Artifacts.CompanyArtifact do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "company_artifacts" do
    field :organization_id, :integer
    field :kind, :string
    field :public_id, :string
    field :head_revision_id, :string
    field :created_at, :utc_datetime
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:id, :organization_id, :kind, :public_id, :head_revision_id, :created_at])
    |> validate_required([:id, :organization_id, :kind, :public_id, :created_at])
    |> validate_inclusion(:kind, ~w(skill spec tool prompt))
    |> unique_constraint([:organization_id, :kind, :public_id])
  end
end

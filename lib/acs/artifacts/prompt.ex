defmodule Acs.Artifacts.Prompt do
  use Ecto.Schema
  import Ecto.Changeset

  schema "acs_prompts" do
    field :organization_id, :integer
    field :company_artifact_id, :string
    field :head_revision_id, :string
    field :public_id, :string
    field :category, :string
    field :name, :string
    field :status, :string
    field :content, :string
    field :snapshot_json, :string
  end

  def changeset(prompt, attrs) do
    prompt
    |> cast(attrs, [
      :organization_id,
      :company_artifact_id,
      :head_revision_id,
      :public_id,
      :category,
      :name,
      :status,
      :content,
      :snapshot_json
    ])
    |> validate_required([
      :organization_id,
      :company_artifact_id,
      :head_revision_id,
      :public_id,
      :category,
      :name,
      :snapshot_json
    ])
    |> unique_constraint([:organization_id, :company_artifact_id])
  end
end

defmodule Acs.Memory.Schema do
  @moduledoc """
  Current-memory query projection.

  In single-tenant mode this is derived from canonical YAML/Markdown files. In
  multi-tenant mode it is a rebuildable projection of the immutable database
  revision ledger; `head_revision_id` identifies the canonical snapshot.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @status_types Acs.Governance.Status.primary_statuses() ++ ~w(stale archived parse_error)

  @derive {Jason.Encoder,
           only: [:id, :kind, :status, :title, :summary, :content, :scope_path, :importance]}
  @primary_key {:id, :string, []}
  schema "acs_memories" do
    field :kind, :string
    field :status, :string, default: "proposed"
    field :title, :string
    field :summary, :string
    field :content, :string
    field :scope_path, :string
    field :importance, :integer, default: 3
    field :tags_json, :string
    field :triggers_json, :string
    field :failure_modes_json, :string
    field :related_memories_json, :string
    field :verification_json, :string
    field :revalidation_json, :string
    field :created_by_json, :string
    field :created_by_agent, :string
    field :parse_error, :string
    field :file_path, :string
    field :auditor_flags, :string
    field :audience, :string
    field :repo, :string
    field :origin, :string
    field :team, :string
    field :project, :string
    field :visibility, :string, default: "org"
    field :org, :string, default: "default"
    field :authority_sort_order, :integer
    field :company_memory_id, :string
    field :head_revision_id, :string
    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :id,
      :kind,
      :status,
      :title,
      :summary,
      :content,
      :scope_path,
      :importance,
      :tags_json,
      :triggers_json,
      :failure_modes_json,
      :related_memories_json,
      :verification_json,
      :revalidation_json,
      :created_by_json,
      :created_by_agent,
      :parse_error,
      :file_path,
      :auditor_flags,
      :audience,
      :repo,
      :origin,
      :team,
      :project,
      :visibility,
      :org,
      :authority_sort_order,
      :company_memory_id,
      :head_revision_id
    ])
    |> validate_required([:id, :kind, :title, :content, :scope_path])
    |> validate_inclusion(
      :kind,
      ~w(observation learning warning pattern bug decision invariant axiom context status work_note activity)
    )
    |> validate_inclusion(
      :status,
      @status_types
    )
  end
end

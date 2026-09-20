defmodule Acs.Acs.File do
  @moduledoc """
  An uploaded file managed by the `manage_files` MCP tool.

  Files are org-scoped, optionally attached to a task, and expire 24 hours
  after upload. `Acs.Files.Reaper` deletes expired rows and their stored
  bytes; expired-but-unreaped files are treated as not found by the tool.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :org,
             :filename,
             :content_type,
             :size_bytes,
             :storage_path,
             :task_id,
             :uploaded_by_agent,
             :expires_at,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "acs_files" do
    field(:org, :string, default: "default")
    field(:filename, :string)
    field(:content_type, :string)
    field(:size_bytes, :integer)
    field(:storage_path, :string)
    field(:task_id, :binary_id)
    field(:uploaded_by_agent, :string)
    field(:expires_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(file, attrs) do
    file
    |> cast(attrs, [
      :org,
      :filename,
      :content_type,
      :size_bytes,
      :storage_path,
      :task_id,
      :uploaded_by_agent,
      :expires_at
    ])
    |> validate_required([:org, :filename, :size_bytes, :storage_path, :expires_at])
  end
end

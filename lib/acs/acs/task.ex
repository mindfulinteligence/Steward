defmodule Acs.Acs.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :slug,
             :title,
             :description,
             :status,
             :kind,
             :assignee,
             :due_at,
             :remind_at,
             :authority_sort_order,
             :created_by_agent,
             :locked_by_agent,
             :locked_at,
             :auto_release_at,
             :event_count,
             :file_paths,
             :repo,
             :org,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "acs_tasks" do
    field(:slug, :string)
    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "todo")
    field(:kind, :string, default: "coordination")
    field(:assignee, :string)
    field(:due_at, :utc_datetime)
    field(:remind_at, :utc_datetime)
    field(:authority_sort_order, :integer)
    field(:created_by_agent, :string)
    field(:locked_by_agent, :string)
    field(:locked_at, :utc_datetime)
    field(:auto_release_at, :utc_datetime)
    field(:event_count, :integer, default: 1)
    field(:file_paths, {:array, :string}, default: [])
    field(:repo, :string)
    field(:org, :string, default: "default")
    timestamps(type: :utc_datetime)
  end

  def statuses, do: ["todo", "in_progress", "in_review", "done", "blocked", "dismissed"]
  def kinds, do: ["coordination", "user"]
  def user_statuses, do: ["todo", "done", "dismissed"]

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :slug,
      :title,
      :description,
      :status,
      :kind,
      :assignee,
      :due_at,
      :remind_at,
      :authority_sort_order,
      :created_by_agent,
      :locked_by_agent,
      :locked_at,
      :auto_release_at,
      :event_count,
      :file_paths,
      :repo,
      :org
    ])
    |> validate_required([:title, :created_by_agent])
    |> validate_inclusion(:status, statuses())
    |> validate_inclusion(:kind, kinds())
    |> validate_user_task_fields()
  end

  defp validate_user_task_fields(changeset) do
    kind = get_field(changeset, :kind) || "coordination"

    if kind == "user" do
      changeset
      |> validate_required([:assignee, :due_at, :remind_at])
      |> validate_inclusion(:status, user_statuses())
    else
      changeset
    end
  end
end

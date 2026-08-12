defmodule Acs.Acs.TaskCompletionFeedback do
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_completion_feedback" do
    field :task_id, :binary_id
    field :agent_id, :string
    field :org, :string, default: "default"
    field :learned_for_agents, :string
    field :most_time_consuming, :string
    field :improvements_needed, :string
    field :tools_wish_list, :string
    field :info_needed, :string
    field :guidance_useful, :boolean
    field :guidance_items_helpful, :string
    field :guidance_items_confusing, :string
    field :guidance_missing, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(feedback, attrs) do
    feedback
    |> cast(attrs, [
      :task_id,
      :agent_id,
      :org,
      :learned_for_agents,
      :most_time_consuming,
      :improvements_needed,
      :tools_wish_list,
      :info_needed,
      :guidance_useful,
      :guidance_items_helpful,
      :guidance_items_confusing,
      :guidance_missing
    ])
    |> validate_required([:agent_id])
  end
end

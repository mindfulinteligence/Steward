defmodule Acs.Repo.Migrations.RenameFeedbackMostSurprisingToLearnedForAgents do
  use Ecto.Migration

  def change do
    rename(table(:task_completion_feedback), :most_surprising, to: :learned_for_agents)
  end
end

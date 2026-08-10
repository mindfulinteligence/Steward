defmodule Acs.Repo.Migrations.AddRepoToAcsTasks do
  use Ecto.Migration

  def change do
    alter table(:acs_tasks) do
      add(:repo, :string)
    end

    create(index(:acs_tasks, [:org, :repo]))
  end
end

defmodule Acs.Repo.Migrations.AddRepoAndOriginToAcsMemories do
  use Ecto.Migration

  def change do
    alter table(:acs_memories) do
      add :repo, :string
      add :origin, :string
    end
  end
end

defmodule Acs.Repo.Migrations.AddRepoOriginToMemoryEmbeddings do
  use Ecto.Migration

  def change do
    alter table(:memory_embeddings) do
      add(:repo, :string)
      add(:origin, :string)
    end

    create(index(:memory_embeddings, [:org, :repo, :origin]))
  end
end

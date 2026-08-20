defmodule Acs.Repo.Migrations.AddEmbeddingFingerprints do
  use Ecto.Migration

  def change do
    alter table(:memory_embeddings) do
      add(:content_hash, :string)
      add(:embedding_model, :string)
    end
  end
end

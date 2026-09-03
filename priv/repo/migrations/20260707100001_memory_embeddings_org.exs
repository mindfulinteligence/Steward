defmodule Acs.Repo.Migrations.MemoryEmbeddingsOrg do
  use Ecto.Migration

  def up do
    if postgres?() do
      # Clean up partial SQLite-style recreate from a failed earlier attempt.
      execute("DROP TABLE IF EXISTS memory_embeddings_new")

      execute("""
      ALTER TABLE memory_embeddings
        ADD COLUMN IF NOT EXISTS org TEXT NOT NULL DEFAULT 'default'
      """)

      # Raw execute/1 DDL is queued by the migration runner and is not
      # guaranteed to have reached the database before a raw repo().query!
      # call below on a connection that has never seen this table before
      # (fresh install) — flush forces it to be sent first.
      flush()

      configured_org =
        Application.get_env(:steward_acs, :org_name) ||
          Application.get_env(:steward_acs, :cluster_name, "default")

      repo().query!(
        """
        UPDATE memory_embeddings
        SET org = $1
        WHERE org IS NULL OR org = 'default'
        """,
        [configured_org]
      )

      repo().query!(
        """
        UPDATE acs_memories
        SET org = $1
        WHERE org IS NULL OR org = 'default'
        """,
        [configured_org]
      )

      execute("ALTER TABLE memory_embeddings DROP CONSTRAINT IF EXISTS memory_embeddings_pkey")
      execute("ALTER TABLE memory_embeddings ADD PRIMARY KEY (memory_id, org)")
      create_if_not_exists(index(:memory_embeddings, [:org], name: :memory_embeddings_org_index))
    else
      execute("""
      CREATE TABLE memory_embeddings_new (
        memory_id TEXT NOT NULL,
        org TEXT NOT NULL DEFAULT 'default',
        embedding TEXT NOT NULL,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (memory_id, org)
      )
      """)

      flush()

      configured_org =
        Application.get_env(:steward_acs, :org_name) ||
          Application.get_env(:steward_acs, :cluster_name, "default")

      repo().query!(
        """
        INSERT INTO memory_embeddings_new (memory_id, org, embedding, updated_at)
        SELECT memory_id, ?, embedding, updated_at
        FROM memory_embeddings
        """,
        [configured_org]
      )

      repo().query!(
        "UPDATE acs_memories SET org = ? WHERE org IS NULL OR org = 'default'",
        [configured_org]
      )

      execute("DROP TABLE memory_embeddings")
      execute("ALTER TABLE memory_embeddings_new RENAME TO memory_embeddings")
      create(index(:memory_embeddings, [:org], name: :memory_embeddings_org_index))
    end
  end

  def down do
    if postgres?() do
      execute("ALTER TABLE memory_embeddings DROP CONSTRAINT IF EXISTS memory_embeddings_pkey")
      execute("ALTER TABLE memory_embeddings ADD PRIMARY KEY (memory_id)")
      execute("ALTER TABLE memory_embeddings DROP COLUMN IF EXISTS org")
    else
      execute("""
      CREATE TABLE memory_embeddings_old (
        memory_id TEXT NOT NULL PRIMARY KEY,
        embedding TEXT NOT NULL,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
      """)

      execute("""
      INSERT INTO memory_embeddings_old (memory_id, embedding, updated_at)
      SELECT memory_id, embedding, updated_at
      FROM memory_embeddings
      WHERE rowid IN (
        SELECT MIN(rowid) FROM memory_embeddings GROUP BY memory_id
      )
      """)

      execute("DROP TABLE memory_embeddings")
      execute("ALTER TABLE memory_embeddings_old RENAME TO memory_embeddings")
    end
  end

  defp postgres?, do: repo().__adapter__() == Ecto.Adapters.Postgres
end

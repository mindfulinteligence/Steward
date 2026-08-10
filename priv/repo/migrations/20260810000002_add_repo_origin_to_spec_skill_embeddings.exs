defmodule Acs.Repo.Migrations.AddRepoOriginToSpecSkillEmbeddings do
  use Ecto.Migration

  def change do
    add_metadata_columns(:spec_embeddings)
    add_metadata_columns(:skill_embeddings)
  end

  defp add_metadata_columns(table) do
    table_name = Atom.to_string(table)

    if table_exists?(table_name) do
      add_column_if_missing(table_name, "repo")
      add_column_if_missing(table_name, "origin")

      execute(
        "CREATE INDEX IF NOT EXISTS #{table_name}_org_repo_origin_index " <>
          "ON #{table_name} (org, repo, origin)"
      )
    end
  end

  defp table_exists?(table) do
    case repo().query("SELECT 1 FROM #{table} LIMIT 0") do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp add_column_if_missing(table, column) do
    case repo().query("SELECT #{column} FROM #{table} LIMIT 0") do
      {:ok, _} -> :ok
      _ -> execute("ALTER TABLE #{table} ADD COLUMN #{column} TEXT")
    end
  end
end

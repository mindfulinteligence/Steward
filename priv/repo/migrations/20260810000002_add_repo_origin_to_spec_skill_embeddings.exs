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
    case repo().__adapter__() do
      Ecto.Adapters.Postgres ->
        {:ok, %{rows: [[exists]]}} =
          repo().query(
            "SELECT EXISTS (SELECT 1 FROM information_schema.tables " <>
              "WHERE table_schema = current_schema() AND table_name = $1)",
            [table]
          )

        exists

      Ecto.Adapters.SQLite3 ->
        {:ok, %{rows: rows}} =
          repo().query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            [table]
          )

        rows != []

      _ ->
        false
    end
  end

  defp add_column_if_missing(table, column) do
    column_exists? =
      case repo().__adapter__() do
        Ecto.Adapters.Postgres ->
          {:ok, %{rows: [[exists]]}} =
            repo().query(
              "SELECT EXISTS (SELECT 1 FROM information_schema.columns " <>
                "WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2)",
              [table, column]
            )

          exists

        Ecto.Adapters.SQLite3 ->
          {:ok, %{rows: rows}} = repo().query("PRAGMA table_info(#{table})")
          Enum.any?(rows, fn row -> Enum.at(row, 1) == column end)

        _ ->
          false
      end

    unless column_exists? do
      execute("ALTER TABLE #{table} ADD COLUMN #{column} TEXT")
    end
  end
end

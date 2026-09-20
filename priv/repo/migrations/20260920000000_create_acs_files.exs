defmodule Acs.Repo.Migrations.CreateAcsFiles do
  use Ecto.Migration

  def up do
    create table(:acs_files, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org, :string, null: false, default: "default")
      add(:filename, :string, null: false)
      add(:content_type, :string)
      add(:size_bytes, :integer, null: false)
      add(:storage_path, :string, null: false)
      add(:task_id, references(:acs_tasks, type: :binary_id))
      add(:uploaded_by_agent, :string)
      add(:expires_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:acs_files, [:org]))
    create(index(:acs_files, [:task_id]))
    create(index(:acs_files, [:expires_at]))
  end

  def down do
    drop(table(:acs_files))
  end
end

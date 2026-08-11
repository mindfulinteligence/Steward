defmodule Acs.Repo.Migrations.AddTextDescriptionToAcsTasks do
  use Ecto.Migration

  def up do
    # Postgres: varchar(255) truncates long create_work descriptions at insert and
    # raises, surfacing as a generic "Tool execution failed". Widen to text.
    # SQLite: no-op — varchar columns already accept unbounded strings there.
    if Acs.Repo.__adapter__() == Ecto.Adapters.Postgres do
      alter table(:acs_tasks) do
        modify(:description, :text)
      end
    end
  end

  def down do
    if Acs.Repo.__adapter__() == Ecto.Adapters.Postgres do
      alter table(:acs_tasks) do
        modify(:description, :string)
      end
    end
  end
end

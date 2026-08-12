defmodule Acs.Repo.Migrations.AddKindToDeveloperKeys do
  use Ecto.Migration

  def up do
    alter table(:acs_developer_api_keys) do
      add :kind, :string, null: false, default: "code"
    end
  end

  def down do
    alter table(:acs_developer_api_keys) do
      remove :kind
    end
  end
end

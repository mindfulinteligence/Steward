defmodule Acs.Repo.Migrations.AddPromptArtifacts do
  use Ecto.Migration

  def up do
    create table(:acs_prompts) do
      add(:organization_id, references(:organizations, on_delete: :restrict), null: false)

      add(
        :company_artifact_id,
        references(:company_artifacts, type: :string, on_delete: :restrict), null: false)

      add(:head_revision_id, references(:artifact_revisions, type: :string, on_delete: :restrict),
        null: false
      )

      add(:public_id, :string, null: false)
      add(:category, :string, null: false)
      add(:name, :string, null: false)
      add(:status, :string)
      add(:content, :text)
      add(:snapshot_json, :text, null: false)
    end

    create(unique_index(:acs_prompts, [:organization_id, :company_artifact_id]))
    create(unique_index(:acs_prompts, [:organization_id, :public_id]))
    create(index(:acs_prompts, [:organization_id, :category, :name]))

    extend_kind_guards()
    install_prompt_projection_guard()
  end

  def down do
    remove_prompt_projection_guard()
    restore_kind_guards()
    drop(table(:acs_prompts))
  end

  defp extend_kind_guards do
    if postgres?() do
      execute("""
      CREATE OR REPLACE FUNCTION validate_company_artifact_head() RETURNS trigger AS $$
      BEGIN
        IF NEW.kind NOT IN ('skill', 'spec', 'tool', 'prompt') THEN
          RAISE EXCEPTION 'invalid artifact kind';
        END IF;
        IF TG_OP = 'UPDATE' AND (
          NEW.id IS DISTINCT FROM OLD.id OR
          NEW.organization_id IS DISTINCT FROM OLD.organization_id OR
          NEW.kind IS DISTINCT FROM OLD.kind OR
          NEW.public_id IS DISTINCT FROM OLD.public_id OR
          NEW.created_at IS DISTINCT FROM OLD.created_at
        ) THEN
          RAISE EXCEPTION 'artifact identity fields are immutable';
        END IF;
        IF NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id
            AND r.organization_id = NEW.organization_id
            AND r.artifact_id = NEW.id
        ) THEN
          RAISE EXCEPTION 'invalid or cross-tenant company artifact head';
        END IF;
        IF TG_OP = 'UPDATE' AND OLD.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id
            AND r.parent_revision_id = OLD.head_revision_id
        ) THEN
          RAISE EXCEPTION 'company artifact head must advance to a direct child revision';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)
    else
      execute("DROP TRIGGER IF EXISTS company_artifacts_validate_insert")
      execute("DROP TRIGGER IF EXISTS company_artifacts_validate_head")

      execute("""
      CREATE TRIGGER company_artifacts_validate_insert
      BEFORE INSERT ON company_artifacts BEGIN
        SELECT CASE WHEN NEW.kind NOT IN ('skill', 'spec', 'tool', 'prompt')
          THEN RAISE(ABORT, 'invalid artifact kind') END;
        SELECT CASE WHEN NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id AND r.organization_id = NEW.organization_id AND r.artifact_id = NEW.id
        ) THEN RAISE(ABORT, 'invalid company artifact head') END;
      END;
      """)

      execute("""
      CREATE TRIGGER company_artifacts_validate_head
      BEFORE UPDATE ON company_artifacts BEGIN
        SELECT CASE WHEN NEW.id <> OLD.id OR NEW.organization_id <> OLD.organization_id OR
          NEW.kind <> OLD.kind OR NEW.public_id <> OLD.public_id OR NEW.created_at <> OLD.created_at
          THEN RAISE(ABORT, 'artifact identity fields are immutable') END;
        SELECT CASE WHEN NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id AND r.organization_id = NEW.organization_id AND r.artifact_id = NEW.id
        ) THEN RAISE(ABORT, 'invalid company artifact head') END;
        SELECT CASE WHEN OLD.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id AND r.parent_revision_id = OLD.head_revision_id
        ) THEN RAISE(ABORT, 'company artifact head must advance to a direct child revision') END;
      END;
      """)
    end
  end

  defp install_prompt_projection_guard do
    if postgres?() do
      execute(
        "CREATE TRIGGER acs_prompts_validate_artifact BEFORE INSERT OR UPDATE ON acs_prompts FOR EACH ROW EXECUTE FUNCTION validate_artifact_projection('prompt')"
      )
    else
      install_sqlite_projection_guard("acs_prompts", "prompt")
    end
  end

  defp install_sqlite_projection_guard(table, kind) do
    for event <- ["INSERT", "UPDATE"] do
      transition_guard =
        if event == "UPDATE" do
          """
          SELECT CASE WHEN NEW.company_artifact_id <> OLD.company_artifact_id OR
            NEW.organization_id <> OLD.organization_id OR NEW.head_revision_id = OLD.head_revision_id OR
            NOT EXISTS (SELECT 1 FROM artifact_revisions r
              WHERE r.id = NEW.head_revision_id AND r.parent_revision_id = OLD.head_revision_id)
            THEN RAISE(ABORT, 'artifact projection must advance to a direct child revision') END;
          """
        else
          ""
        end

      execute("""
      CREATE TRIGGER #{table}_validate_artifact_#{String.downcase(event)}
      BEFORE #{event} ON #{table} BEGIN
        SELECT CASE WHEN NOT EXISTS (
          SELECT 1 FROM company_artifacts a
          JOIN artifact_revisions r ON r.id = NEW.head_revision_id
          WHERE a.id = NEW.company_artifact_id
            AND a.organization_id = NEW.organization_id
            AND a.kind = '#{kind}'
            AND a.head_revision_id = NEW.head_revision_id
            AND r.organization_id = NEW.organization_id
            AND r.artifact_id = a.id
            AND r.snapshot_json = NEW.snapshot_json
        ) THEN RAISE(ABORT, 'invalid artifact projection head, kind, or snapshot') END;
        #{transition_guard}
      END;
      """)
    end
  end

  defp remove_prompt_projection_guard do
    if postgres?() do
      execute("DROP TRIGGER IF EXISTS acs_prompts_validate_artifact ON acs_prompts")
    else
      execute("DROP TRIGGER IF EXISTS acs_prompts_validate_artifact_insert")
      execute("DROP TRIGGER IF EXISTS acs_prompts_validate_artifact_update")
    end
  end

  defp restore_kind_guards do
    if postgres?() do
      execute("""
      CREATE OR REPLACE FUNCTION validate_company_artifact_head() RETURNS trigger AS $$
      BEGIN
        IF NEW.kind NOT IN ('skill', 'spec', 'tool') THEN
          RAISE EXCEPTION 'invalid artifact kind';
        END IF;
        IF TG_OP = 'UPDATE' AND (
          NEW.id IS DISTINCT FROM OLD.id OR
          NEW.organization_id IS DISTINCT FROM OLD.organization_id OR
          NEW.kind IS DISTINCT FROM OLD.kind OR
          NEW.public_id IS DISTINCT FROM OLD.public_id OR
          NEW.created_at IS DISTINCT FROM OLD.created_at
        ) THEN
          RAISE EXCEPTION 'artifact identity fields are immutable';
        END IF;
        IF NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id
            AND r.organization_id = NEW.organization_id
            AND r.artifact_id = NEW.id
        ) THEN
          RAISE EXCEPTION 'invalid or cross-tenant company artifact head';
        END IF;
        IF TG_OP = 'UPDATE' AND OLD.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id
            AND r.parent_revision_id = OLD.head_revision_id
        ) THEN
          RAISE EXCEPTION 'company artifact head must advance to a direct child revision';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)
    else
      execute("DROP TRIGGER IF EXISTS company_artifacts_validate_insert")
      execute("DROP TRIGGER IF EXISTS company_artifacts_validate_head")

      execute("""
      CREATE TRIGGER company_artifacts_validate_insert
      BEFORE INSERT ON company_artifacts BEGIN
        SELECT CASE WHEN NEW.kind NOT IN ('skill', 'spec', 'tool')
          THEN RAISE(ABORT, 'invalid artifact kind') END;
        SELECT CASE WHEN NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id AND r.organization_id = NEW.organization_id AND r.artifact_id = NEW.id
        ) THEN RAISE(ABORT, 'invalid company artifact head') END;
      END;
      """)

      execute("""
      CREATE TRIGGER company_artifacts_validate_head
      BEFORE UPDATE ON company_artifacts BEGIN
        SELECT CASE WHEN NEW.id <> OLD.id OR NEW.organization_id <> OLD.organization_id OR
          NEW.kind <> OLD.kind OR NEW.public_id <> OLD.public_id OR NEW.created_at <> OLD.created_at
          THEN RAISE(ABORT, 'artifact identity fields are immutable') END;
        SELECT CASE WHEN NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id AND r.organization_id = NEW.organization_id AND r.artifact_id = NEW.id
        ) THEN RAISE(ABORT, 'invalid company artifact head') END;
        SELECT CASE WHEN OLD.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id AND r.parent_revision_id = OLD.head_revision_id
        ) THEN RAISE(ABORT, 'company artifact head must advance to a direct child revision') END;
      END;
      """)
    end
  end

  defp postgres?, do: to_string(repo().__adapter__()) == "Elixir.Ecto.Adapters.Postgres"
end

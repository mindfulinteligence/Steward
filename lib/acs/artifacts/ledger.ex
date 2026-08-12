defmodule Acs.Artifacts.Ledger do
  import Ecto.Query

  alias Acs.Artifacts.{Commit, CompanyArtifact, Prompt, Revision, Skill, Spec, TenantTool}
  alias Acs.Orgs.Organization
  alias Acs.Repo

  @kinds ~w(skill spec tool prompt)
  @operations ~w(create revise transition restore tombstone import)

  @doc "Append an artifact snapshot and rebuild its current-kind projection."
  def save(kind, public_id, snapshot, opts \\ []) when is_map(snapshot) do
    kind = to_string(kind)
    org = Keyword.get(opts, :org, Acs.Org.current())

    with :ok <- validate_kind(kind),
         :ok <- validate_public_id(public_id),
         {:ok, organization} <- resolve_org(org),
         {:ok, snapshot} <- normalize_snapshot(snapshot),
         {:ok, projection} <- projection_attrs(kind, public_id, snapshot) do
      actor = normalize_actor(Keyword.get(opts, :actor))
      source = opts |> Keyword.get(:source, "system") |> to_string()
      requested_operation = Keyword.get(opts, :operation)
      message = Keyword.get(opts, :message, "Save #{kind} #{public_id}")
      request_id = Keyword.get(opts, :request_id)
      expected_head = Keyword.get(opts, :expected_head_revision_id)
      metadata_json = opts |> Keyword.get(:metadata, %{}) |> stringify() |> Jason.encode!()

      Repo.transaction(fn ->
        lock_tenant_ledger!(organization.id)
        artifact = get_or_create_artifact!(organization.id, kind, public_id)
        parent = get_head_revision(artifact)
        operation = default_operation(requested_operation, parent)

        if operation == "invalid", do: Repo.rollback(:invalid_operation)
        if parent && is_nil(expected_head), do: Repo.rollback(:expected_head_revision_required)

        if operation == "revise" && is_nil(expected_head),
          do: Repo.rollback(:expected_head_revision_required)

        verify_expected_head!(parent, expected_head)

        now = DateTime.utc_now() |> DateTime.truncate(:second)
        snapshot_json = Jason.encode!(snapshot)
        content_hash = canonical_hash(snapshot)
        revision_id = Ecto.UUID.generate()
        revision_number = if parent, do: parent.revision_number + 1, else: 1
        parent_revision_hash = parent && parent.revision_hash

        revision_hash =
          canonical_hash(%{
            organization_id: organization.id,
            artifact_id: artifact.id,
            revision_number: revision_number,
            parent_revision_hash: parent_revision_hash,
            operation: operation,
            content_hash: content_hash,
            metadata_json: metadata_json
          })

        latest = latest_commit(organization.id)
        commit_id = Ecto.UUID.generate()
        sequence = if latest, do: latest.sequence + 1, else: 1

        commit =
          %Commit{}
          |> Commit.changeset(%{
            id: commit_id,
            organization_id: organization.id,
            sequence: sequence,
            parent_commit_id: latest && latest.id,
            parent_commit_hash: latest && latest.commit_hash,
            actor_type: actor.type,
            actor_id: actor.id,
            actor_display: actor.display,
            message: message,
            source: source,
            request_id: request_id,
            committed_at: now,
            commit_hash:
              commit_hash(%{
                organization_id: organization.id,
                sequence: sequence,
                parent_hash: latest && latest.commit_hash,
                revision_id: revision_id,
                revision_hash: revision_hash,
                actor: actor,
                message: message,
                source: source,
                committed_at: now
              })
          })
          |> Repo.insert!()

        revision =
          %Revision{}
          |> Revision.changeset(%{
            id: revision_id,
            organization_id: organization.id,
            artifact_id: artifact.id,
            revision_number: revision_number,
            parent_revision_id: parent && parent.id,
            parent_revision_hash: parent_revision_hash,
            commit_id: commit.id,
            operation: operation,
            snapshot_json: snapshot_json,
            metadata_json: metadata_json,
            content_hash: content_hash,
            revision_hash: revision_hash,
            inserted_at: now
          })
          |> Repo.insert!()

        artifact
        |> CompanyArtifact.changeset(%{head_revision_id: revision.id})
        |> Repo.update!()

        upsert_projection!(
          kind,
          projection,
          organization.id,
          artifact.id,
          revision.id,
          snapshot_json
        )

        %{snapshot: snapshot, revision: revision, commit: commit}
      end)
    else
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, {:ledger_write_failed, Exception.message(error)}}
  end

  @doc "Return immutable revisions oldest-first for one artifact."
  def history(public_id, kind, org \\ Acs.Org.current()) do
    kind = to_string(kind)

    with :ok <- validate_kind(kind),
         {:ok, %Organization{id: organization_id}} <- resolve_org(org),
         %CompanyArtifact{id: artifact_id} <-
           Repo.get_by(CompanyArtifact,
             organization_id: organization_id,
             kind: kind,
             public_id: public_id
           ) do
      Repo.all(
        from r in Revision,
          where: r.organization_id == ^organization_id and r.artifact_id == ^artifact_id,
          order_by: [asc: r.revision_number]
      )
    else
      _ -> []
    end
  end

  @doc "Decode an immutable artifact revision snapshot."
  def snapshot(%Revision{snapshot_json: json}), do: Jason.decode(json)

  @doc "Verify commit/revision hashes, parent links, and current projections for an organization."
  def verify(org \\ Acs.Org.current()) do
    with {:ok, %Organization{id: organization_id}} <- resolve_org(org) do
      commits =
        Repo.all(
          from c in Commit,
            where: c.organization_id == ^organization_id,
            order_by: [asc: c.sequence]
        )

      revisions = Repo.all(from r in Revision, where: r.organization_id == ^organization_id)
      revisions_by_commit = Map.new(revisions, &{&1.commit_id, &1})
      revisions_by_id = Map.new(revisions, &{&1.id, &1})

      Enum.reduce_while(commits, {:ok, nil}, fn commit, {:ok, previous} ->
        revision = Map.get(revisions_by_commit, commit.id)
        parent = revision && Map.get(revisions_by_id, revision.parent_revision_id)

        expected_commit_hash =
          revision &&
            commit_hash(%{
              organization_id: organization_id,
              sequence: commit.sequence,
              parent_hash: previous && previous.commit_hash,
              revision_id: revision.id,
              revision_hash: revision.revision_hash,
              actor: %{
                type: commit.actor_type,
                id: commit.actor_id,
                display: commit.actor_display
              },
              message: commit.message,
              source: commit.source,
              committed_at: commit.committed_at
            })

        expected_revision_hash =
          revision &&
            canonical_hash(%{
              organization_id: revision.organization_id,
              artifact_id: revision.artifact_id,
              revision_number: revision.revision_number,
              parent_revision_hash: revision.parent_revision_hash,
              operation: revision.operation,
              content_hash: revision.content_hash,
              metadata_json: revision.metadata_json
            })

        valid_snapshot? =
          case revision && Jason.decode(revision.snapshot_json) do
            {:ok, value} -> canonical_hash(value) == revision.content_hash
            _ -> false
          end

        valid_parent? =
          if revision && revision.revision_number == 1 do
            is_nil(revision.parent_revision_id) and is_nil(revision.parent_revision_hash)
          else
            revision && parent && parent.artifact_id == revision.artifact_id &&
              parent.revision_number + 1 == revision.revision_number &&
              parent.revision_hash == revision.parent_revision_hash
          end

        if revision && valid_snapshot? && valid_parent? &&
             expected_revision_hash == revision.revision_hash &&
             expected_commit_hash == commit.commit_hash &&
             commit.sequence == if(previous, do: previous.sequence + 1, else: 1) &&
             commit.parent_commit_id == (previous && previous.id) &&
             commit.parent_commit_hash == (previous && previous.commit_hash) do
          {:cont, {:ok, commit}}
        else
          {:halt, {:error, {:invalid_commit, commit.id}}}
        end
      end)
      |> case do
        {:ok, _} when length(commits) == length(revisions) ->
          if heads_valid?(organization_id), do: :ok, else: {:error, :orphan_or_invalid_head}

        {:ok, _} ->
          {:error, :orphan_or_invalid_head}

        error ->
          error
      end
    else
      {:error, _} = error -> error
    end
  end

  defp resolve_org(%Organization{} = organization), do: {:ok, organization}

  defp resolve_org(slug) when is_binary(slug) do
    case Repo.get_by(Organization, slug: slug) do
      nil -> {:error, {:organization_not_found, slug}}
      organization -> {:ok, organization}
    end
  end

  defp resolve_org(org), do: {:error, {:organization_not_found, org}}

  defp get_or_create_artifact!(organization_id, kind, public_id) do
    query =
      from a in CompanyArtifact,
        where:
          a.organization_id == ^organization_id and a.kind == ^kind and a.public_id == ^public_id

    query = if postgres?(), do: from(a in query, lock: "FOR UPDATE"), else: query

    Repo.one(query) ||
      %CompanyArtifact{}
      |> CompanyArtifact.changeset(%{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        kind: kind,
        public_id: public_id,
        created_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()
  end

  defp get_head_revision(%CompanyArtifact{head_revision_id: nil}), do: nil
  defp get_head_revision(%CompanyArtifact{head_revision_id: id}), do: Repo.get!(Revision, id)

  defp latest_commit(organization_id) do
    Repo.one(
      from c in Commit,
        where: c.organization_id == ^organization_id,
        order_by: [desc: c.sequence],
        limit: 1
    )
  end

  defp verify_expected_head!(_parent, nil), do: :ok
  defp verify_expected_head!(%Revision{id: expected}, expected), do: :ok

  defp verify_expected_head!(parent, expected) do
    Repo.rollback({:conflict, %{expected_head: expected, actual_head: parent && parent.id}})
  end

  defp lock_tenant_ledger!(organization_id) do
    if postgres?() do
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [organization_id])
    end

    :ok
  end

  defp projection_attrs("skill", public_id, snapshot) do
    with {:ok, name} <- required(snapshot, "name") do
      {:ok,
       %{
         public_id: public_id,
         name: name,
         description: optional(snapshot, "description"),
         status: optional(snapshot, "status"),
         tags_json: json_value(snapshot, "tags"),
         scope_paths_json: json_value(snapshot, "scope_paths"),
         content: optional(snapshot, "content")
       }}
    end
  end

  defp projection_attrs("spec", public_id, snapshot) do
    with {:ok, app} <- required(snapshot, "app"),
         {:ok, spec_id} <- required(snapshot, "id") do
      {:ok,
       %{
         public_id: public_id,
         app: app,
         spec_id: spec_id,
         title: optional(snapshot, "title"),
         status: optional(snapshot, "status"),
         document_type: optional(snapshot, "document_type"),
         tags_json: json_value(snapshot, "tags"),
         content: optional(snapshot, "content")
       }}
    end
  end

  defp projection_attrs("tool", public_id, snapshot) do
    with {:ok, app} <- required(snapshot, "app"),
         {:ok, name} <- required(snapshot, "name") do
      {:ok,
       %{
         public_id: public_id,
         app: app,
         name: name,
         description: optional(snapshot, "description"),
         category: optional(snapshot, "category"),
         definition_json: Jason.encode!(Map.get(snapshot, "definition", snapshot))
       }}
    end
  end

  defp projection_attrs("prompt", public_id, snapshot) do
    with {:ok, category} <- required(snapshot, "category"),
         {:ok, name} <- required(snapshot, "name") do
      {:ok,
       %{
         public_id: public_id,
         category: category,
         name: name,
         status: optional(snapshot, "status"),
         content: optional(snapshot, "content")
       }}
    end
  end

  defp upsert_projection!(kind, attrs, organization_id, artifact_id, revision_id, snapshot_json) do
    {schema, fields} = projection_schema(kind)

    attrs =
      attrs
      |> Map.merge(%{
        organization_id: organization_id,
        company_artifact_id: artifact_id,
        head_revision_id: revision_id,
        snapshot_json: snapshot_json
      })

    changeset = schema.changeset(struct(schema), attrs)

    case Repo.insert(changeset,
           on_conflict: {:replace, fields},
           conflict_target: [:organization_id, :company_artifact_id]
         ) do
      {:ok, _} -> :ok
      {:error, changeset} -> Repo.rollback({:projection_failed, changeset})
    end
  end

  defp projection_schema("skill") do
    {Skill,
     ~w(public_id name description status tags_json scope_paths_json content snapshot_json head_revision_id)a}
  end

  defp projection_schema("spec") do
    {Spec,
     ~w(public_id app spec_id title status document_type tags_json content snapshot_json head_revision_id)a}
  end

  defp projection_schema("tool") do
    {TenantTool,
     ~w(public_id app name description category definition_json snapshot_json head_revision_id)a}
  end

  defp projection_schema("prompt") do
    {Prompt, ~w(public_id category name status content snapshot_json head_revision_id)a}
  end

  defp heads_valid?(organization_id) do
    Repo.all(from a in CompanyArtifact, where: a.organization_id == ^organization_id)
    |> Enum.all?(fn artifact ->
      revision = Repo.get(Revision, artifact.head_revision_id)
      projection = projection_for(artifact.kind, organization_id, artifact.id)

      latest =
        Repo.one(
          from r in Revision,
            where: r.organization_id == ^organization_id and r.artifact_id == ^artifact.id,
            order_by: [desc: r.revision_number],
            limit: 1
        )

      revision && latest && projection && revision.id == latest.id &&
        revision.organization_id == organization_id && revision.artifact_id == artifact.id &&
        projection.head_revision_id == revision.id &&
        projection.snapshot_json == revision.snapshot_json
    end)
  end

  defp projection_for("skill", organization_id, artifact_id),
    do: Repo.get_by(Skill, organization_id: organization_id, company_artifact_id: artifact_id)

  defp projection_for("spec", organization_id, artifact_id),
    do: Repo.get_by(Spec, organization_id: organization_id, company_artifact_id: artifact_id)

  defp projection_for("tool", organization_id, artifact_id),
    do:
      Repo.get_by(TenantTool, organization_id: organization_id, company_artifact_id: artifact_id)

  defp projection_for("prompt", organization_id, artifact_id),
    do: Repo.get_by(Prompt, organization_id: organization_id, company_artifact_id: artifact_id)

  defp validate_kind(kind) when kind in @kinds, do: :ok
  defp validate_kind(_kind), do: {:error, :invalid_kind}
  defp validate_public_id(public_id) when is_binary(public_id) and public_id != "", do: :ok
  defp validate_public_id(_public_id), do: {:error, :invalid_public_id}

  defp normalize_snapshot(snapshot) do
    snapshot = stringify(snapshot)

    if Jason.encode(snapshot) == {:error, :invalid},
      do: {:error, :invalid_snapshot},
      else: {:ok, snapshot}
  rescue
    Protocol.UndefinedError -> {:error, :invalid_snapshot}
  end

  defp required(snapshot, field) do
    case Map.get(snapshot, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_projection, field}}
    end
  end

  defp optional(snapshot, field) do
    case Map.get(snapshot, field) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp json_value(snapshot, field) do
    case Map.fetch(snapshot, field) do
      {:ok, value} -> Jason.encode!(value)
      :error -> nil
    end
  end

  defp default_operation(nil, nil), do: "create"
  defp default_operation(nil, _parent), do: "revise"
  defp default_operation(operation, _parent) when operation in @operations, do: operation
  defp default_operation(_operation, _parent), do: "invalid"

  defp normalize_actor(actor) when is_map(actor) do
    %{
      type: actor[:type] || actor["type"] || "agent",
      id: to_string(actor[:id] || actor["id"] || "unknown"),
      display: actor[:display] || actor["display"] || actor[:name] || actor["name"]
    }
  end

  defp normalize_actor(_actor), do: %{type: "system", id: "unknown", display: nil}

  defp canonical_hash(value), do: value |> canonical_term() |> Jason.encode!() |> sha256()

  defp canonical_term(value) when is_map(value) do
    [
      "map"
      | value
        |> Enum.map(fn {key, item} -> [to_string(key), canonical_term(item)] end)
        |> Enum.sort()
    ]
  end

  defp canonical_term(value) when is_list(value),
    do: ["list" | Enum.map(value, &canonical_term/1)]

  defp canonical_term(value), do: value

  defp commit_hash(fields) do
    fields
    |> Map.update!(:committed_at, &DateTime.to_iso8601/1)
    |> canonical_hash()
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp postgres?, do: to_string(Acs.Repo.__adapter__()) == "Elixir.Ecto.Adapters.Postgres"
end

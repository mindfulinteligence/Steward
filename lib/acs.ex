defmodule Acs do
  @moduledoc """
  Agent Coordination System - task locking, file locking, and present status tracking.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Acs.Repo
  alias Acs.Acs.Task, as: AcsTask
  alias Acs.Acs.FileLock
  alias Acs.Acs.AgentStatus
  alias Acs.Acs.Cache
  alias Acs.Acs.Similarity
  alias Acs.Memory.Guidance
  alias Acs.Memory.Retry
  alias Acs.Org, as: Org

  @doc false
  def broadcast(event, payload) do
    Phoenix.PubSub.broadcast(AcsWeb.PubSub, "acs", {event, payload})
  end

  # ============================================================================
  # Task Operations
  # ============================================================================

  @doc """
  Creates a new task.
  """
  def create_task(attrs, agent_id) when is_binary(agent_id) do
    attrs = normalize_attrs(attrs)
    title = attrs["title"] || ""
    _description = attrs["description"] || ""
    file_paths = attrs["file_paths"] || []

    case check_no_duplicate_title(title) do
      {:error, _} = error ->
        error

      :ok ->
        similar = Similarity.find_similar_tasks(title, file_paths)

        org = Org.current()

        task_attrs =
          attrs
          |> Map.drop(["org", "org_id", "cluster"])
          |> Map.merge(%{
            "created_by_agent" => agent_id,
            "org" => org,
            "status" => Map.get(attrs, "status", "todo")
          })

        task_attrs =
          if task_attrs["status"] == "claimed" do
            Map.put(task_attrs, "locked_by_agent", agent_id)
          else
            task_attrs
          end

        task_attrs = Map.put(task_attrs, "slug", unique_slug(title, org))

        case Retry.with_busy_retry(fn ->
               %AcsTask{} |> AcsTask.changeset(task_attrs) |> Repo.insert()
             end) do
          {:ok, task} = result ->
            Cache.put_task(task.id, to_task_map(task))
            broadcast(:task_created, %{task_id: task.id, title: task.title})
            if Enum.any?(similar), do: {:warn, task, similar}, else: result

          error ->
            error
        end
    end
  end

  @doc """
  Updates/bumps a task — increments event_count and optionally updates description.
  Returns `{:ok, updated_task}` or `{:error, reason}`.
  """
  def bump_task(task_id, updates) when is_binary(task_id) do
    case resolve_task(task_id) do
      nil ->
        {:error, :task_not_found}

      task ->
        new_event_count = (task.event_count || 1) + 1
        description = updates["description"] || task.description

        task
        |> AcsTask.changeset(%{
          "event_count" => new_event_count,
          "description" => description
        })
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Cache.put_task(updated.id, to_task_map(updated))
            broadcast(:task_updated, %{task_id: updated.id, event_count: new_event_count})
            {:ok, updated}

          error ->
            error
        end
    end
  end

  @doc """
  Claims a task for an agent.
  """
  def claim_task(task_id, agent_id, opts \\ []) when is_binary(task_id) and is_binary(agent_id) do
    task_id = resolve_task_id(task_id)

    result =
      Retry.with_busy_retry(fn ->
        Repo.transaction(fn ->
          query = from(t in AcsTask, where: t.id == ^task_id and t.org == ^Org.current())
          task = Repo.one(query, lock: "FOR UPDATE")

          case task do
            nil ->
              Repo.rollback({:error, :task_not_found})

            %AcsTask{locked_by_agent: locked_by} when not is_nil(locked_by) ->
              Repo.rollback({:error, :already_locked})

            %AcsTask{} = task ->
              now = DateTime.utc_now()
              auto_release = DateTime.add(now, 10, :minute)

              {:ok, updated} =
                task
                |> AcsTask.changeset(%{
                  "locked_by_agent" => agent_id,
                  "locked_at" => now,
                  "auto_release_at" => auto_release,
                  "status" => "in_progress"
                })
                |> Repo.update()

              updated
          end
        end)
      end)

    case result do
      {:ok, task} ->
        upsert_agent_status(agent_id, task.id, "Working on task", nil, nil)
        Cache.put_task(task.id, to_task_map(task))
        broadcast(:task_claimed, %{task_id: task.id, agent_id: agent_id})
        broadcast(:agent_updated, %{agent_id: agent_id, status: "working"})

        guidance =
          unless opts[:skip_guidance] do
            mode = Keyword.get(opts, :mode, :mcp)

            Acs.Memory.Guidance.for_task(
              task.id,
              guidance_abac_opts(opts, agent_id, tier: :claim, mode: mode)
            )
          end

        {:ok, task, guidance}

      {:error, {:error, reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Releases a task lock.
  """
  def release_task(task_id, agent_id) when is_binary(task_id) and is_binary(agent_id) do
    task_id = resolve_task_id(task_id)

    result =
      Retry.with_busy_retry(fn ->
        Repo.transaction(fn ->
          query = from(t in AcsTask, where: t.id == ^task_id and t.org == ^Org.current())

          case Repo.one(query, lock: "FOR UPDATE") do
            nil ->
              nil

            %{locked_by_agent: locked_by} when not is_nil(locked_by) and locked_by != agent_id ->
              Repo.rollback({:error, :not_owner})

            %{locked_by_agent: nil} ->
              nil

            %AcsTask{} = task ->
              {:ok, updated} =
                task
                |> AcsTask.changeset(%{
                  "locked_by_agent" => nil,
                  "locked_at" => nil,
                  "auto_release_at" => nil,
                  "status" => "done"
                })
                |> Repo.update()

              updated
          end
        end)
      end)

    case result do
      {:ok, nil} ->
        {:error, :task_not_claimed}

      {:ok, task} ->
        release_file_locks_for_task(task_id)
        clear_agent_status(agent_id)
        Cache.put_task(task.id, to_task_map(task))
        broadcast(:task_released, %{task_id: task.id, agent_id: agent_id})
        broadcast(:agent_updated, %{agent_id: agent_id, status: "sleeping"})
        {:ok, task}

      {:error, {:error, reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Updates a task's status.
  """
  def set_task_status(task_id, agent_id, new_status)
      when is_binary(task_id) and is_binary(agent_id) do
    task_id = resolve_task_id(task_id)

    result =
      Repo.transaction(fn ->
        query = from(t in AcsTask, where: t.id == ^task_id and t.org == ^Org.current())
        task = Repo.one(query, lock: "FOR UPDATE")

        case task do
          nil ->
            Repo.rollback({:error, :task_not_found})

          %AcsTask{locked_by_agent: locked_by}
          when not is_nil(locked_by) and locked_by != agent_id ->
            Repo.rollback({:error, :not_owner})

          %AcsTask{} = task ->
            {:ok, updated} =
              task
              |> AcsTask.changeset(%{"status" => new_status})
              |> Repo.update()

            updated
        end
      end)

    case result do
      {:ok, task} ->
        Cache.put_task(task.id, to_task_map(task))
        broadcast(:task_status_changed, %{task_id: task.id, status: new_status})
        clear_agent_status(agent_id)
        {:ok, task}

      {:error, {:error, reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Lists all tasks, optionally filtered by status.
  """
  def list_tasks(status_filter \\ nil, org \\ nil) do
    org = org || Org.current()

    query =
      AcsTask
      |> order_by(desc: :inserted_at)
      |> where([t], t.org == ^org)
      |> where([t], t.kind != "user" or is_nil(t.kind))

    query = if status_filter, do: where(query, [t], t.status == ^status_filter), else: query
    Repo.all(query) |> Enum.map(&to_task_map/1)
  end

  @doc """
  Gets a single task by UUID ID or kebab-case slug.
  """
  def get_task(task_ref) when is_binary(task_ref) do
    resolve_task(task_ref)
  end

  @doc """
  Resolves a task reference (UUID ID or kebab-case slug) to a task struct.
  """
  def resolve_task(task_ref) when is_binary(task_ref) do
    org = Org.current()

    if uuid?(task_ref) do
      Repo.one(from(t in AcsTask, where: t.id == ^task_ref and t.org == ^org))
    else
      Repo.one(from(t in AcsTask, where: t.slug == ^task_ref and t.org == ^org))
    end
  end

  defp resolve_task_id(task_ref) do
    case resolve_task(task_ref) do
      %AcsTask{} = task -> task.id
      nil -> nil
    end
  end

  defp uuid?(ref) when is_binary(ref) do
    Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, ref)
  end

  @doc """
  Resets ALL ACS data.
  """
  def reset_all do
    org = Org.current()
    Repo.delete_all(from f in FileLock, where: f.org == ^org)
    Repo.delete_all(from s in AgentStatus, where: s.org == ^org)
    Repo.delete_all(from t in AcsTask, where: t.org == ^org)

    Cache.get_all_tasks(org) |> Enum.each(&Cache.delete_task(&1.id, org))
    Cache.get_all_file_locks(org) |> Enum.each(&Cache.delete_file_lock(&1.file_path, org))
    Cache.get_all_agent_statuses(org) |> Enum.each(&Cache.delete_agent_status(&1.agent_id, org))
    Logger.info("[Acs] ACS data reset for org=#{org}")
    broadcast(:acs_reset, %{})
    :ok
  end

  # ============================================================================
  # File Lock Operations
  # ============================================================================

  @doc """
  Locks a file for an agent.
  """
  def lock_file(file_path, agent_id, task_id, repo \\ nil)
      when is_binary(file_path) and is_binary(agent_id) and is_binary(task_id) do
    task = get_task(task_id)
    task_id = if is_nil(task), do: task_id, else: task.id

    requested_repo =
      Acs.Repos.normalize(repo) || Acs.Repos.normalize(task && task.repo) || Acs.Repos.repo()

    # Idempotent: already locked by this agent for this file = success
    case Repo.get_by(FileLock,
           file_path: file_path,
           locked_by_agent: agent_id,
           org: Org.current()
         ) do
      %FileLock{task_id: ^task_id} ->
        {:ok, %{status: "already_locked", file_path: file_path, repo: task && task.repo}}

      %FileLock{} ->
        # Locked by different agent or different task
        {:error, :file_locked_by_other}

      _ ->
        :ok
    end
    |> case do
      {:ok, _} = result ->
        result

      {:error, _} = result ->
        result

      :ok ->
        cond do
          is_nil(task) ->
            {:error, :task_not_found}

          not is_nil(task.locked_by_agent) and task.locked_by_agent != agent_id ->
            {:error, :task_not_locked_by_agent}

          is_nil(requested_repo) ->
            {:error, :repo_context_required}

          not is_nil(task.repo) and task.repo != requested_repo ->
            {:error, :repo_mismatch}

          true ->
            now = DateTime.utc_now()
            auto_release = DateTime.add(now, 10, :minute)

            task_result =
              if is_nil(task.repo) do
                task |> AcsTask.changeset(%{"repo" => requested_repo}) |> Repo.update()
              else
                {:ok, task}
              end

            with {:ok, updated_task} <- task_result,
                 {:ok, lock} <-
                   %FileLock{}
                   |> FileLock.changeset(%{
                     "file_path" => file_path,
                     "locked_by_agent" => agent_id,
                     "task_id" => task_id,
                     "org" => Org.current(),
                     "locked_at" => now,
                     "auto_release_at" => auto_release
                   })
                   |> Repo.insert() do
              Cache.put_task(updated_task.id, to_task_map(updated_task))
              Cache.put_file_lock(file_path, to_file_lock_map(lock))

              broadcast(:file_locked, %{
                file_path: file_path,
                agent_id: agent_id,
                task_id: task_id,
                repo: updated_task.repo
              })

              scope_path = scope_from_file_path(file_path)

              guidance =
                if scope_path != "", do: Guidance.generate(scope_path, tier: :claim), else: %{}

              {:ok,
               %{
                 status: "locked",
                 file_path: file_path,
                 repo: updated_task.repo,
                 guidance: guidance
               }}
            else
              {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
                errors = inspect(changeset.errors)

                if String.contains?(errors, "unique_constraint") do
                  {:error, :already_locked}
                else
                  {:error, "Lock failed: #{format_changeset_errors(changeset)}"}
                end

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  @doc """
  Unlocks a file.
  """
  def unlock_file(file_path, agent_id) when is_binary(file_path) and is_binary(agent_id) do
    lock = Repo.get_by(FileLock, file_path: file_path, org: Org.current())

    case lock do
      nil ->
        {:error, :not_found}

      %FileLock{locked_by_agent: locked_by} when locked_by != agent_id ->
        {:error, :not_owner}

      %FileLock{} = lock ->
        Repo.delete(lock)
        Cache.delete_file_lock(file_path)
        broadcast(:file_unlocked, %{file_path: file_path})
        :ok
    end
  end

  @doc """
  Unlocks all files for a specific task.
  """
  def unlock_files_for_task(task_id, agent_id) when is_binary(task_id) and is_binary(agent_id) do
    task = get_task(task_id)

    if is_nil(task) or task.locked_by_agent != agent_id do
      {:error, :not_owner}
    else
      org = Org.current()
      locks = Repo.all(from(f in FileLock, where: f.task_id == ^task.id and f.org == ^org))

      Enum.each(locks, fn lock ->
        Repo.delete(lock)
        Cache.delete_file_lock(lock.file_path, org)
      end)

      broadcast(:file_unlocked, %{task_id: task.id})
      :ok
    end
  end

  @doc """
  Gets all currently locked files.
  """
  def get_locked_files(org \\ nil) do
    org = org || Org.current()
    Repo.all(from(f in FileLock, where: f.org == ^org)) |> Enum.map(&to_file_lock_map/1)
  end

  # ============================================================================
  # Present Status Operations
  # ============================================================================

  @doc """
  Gets the present status of all agents.
  """
  def get_present_status do
    statuses = Acs.Acs.get_present_status()

    task_ids = statuses |> Enum.map(& &1.current_task_id) |> Enum.reject(&is_nil/1)

    org = Org.current()

    tasks_map =
      if task_ids != [] do
        Repo.all(from(t in AcsTask, where: t.id in ^task_ids and t.org == ^org))
        |> Enum.map(&to_task_map/1)
        |> Enum.into(%{}, fn t -> {t.id, t} end)
      else
        %{}
      end

    locks_map =
      if task_ids != [] do
        Repo.all(from(f in FileLock, where: f.task_id in ^task_ids and f.org == ^org))
        |> Enum.group_by(& &1.task_id)
      else
        %{}
      end

    statuses
    |> Enum.map(fn s ->
      task = Map.get(tasks_map, s.current_task_id)
      locks = Map.get(locks_map, s.current_task_id, [])
      locked_files = Enum.map(locks, fn l -> l.file_path end)
      working? = !is_nil(s.current_task_id)

      {s.agent_id,
       %{
         task: task,
         purpose: s.purpose,
         application: s.application,
         component: s.component,
         locked_files: locked_files,
         status: if(working?, do: "working", else: "sleeping")
       }}
    end)
    |> Enum.into(%{})
  end

  defdelegate find_similar_tasks(title, file_paths), to: Similarity

  # ============================================================================
  # Helpers
  # ============================================================================

  defp format_changeset_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end

  defp scope_from_file_path(file_path) do
    file_path
    |> String.split("/")
    |> Enum.slice(0..-2//1)
    |> Enum.join("/")
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    for {k, v} <- attrs, into: %{}, do: {to_string(k), v}
  end

  defp release_file_locks_for_task(task_id) do
    org = Org.current()
    locks = Repo.all(from(f in FileLock, where: f.task_id == ^task_id and f.org == ^org))

    Enum.each(locks, fn lock ->
      Repo.delete(lock)
      Cache.delete_file_lock(lock.file_path, org)
    end)
  end

  defp upsert_agent_status(agent_id, task_id, purpose, application, component) do
    case Repo.get_by(AgentStatus, agent_id: agent_id, org: Org.current()) do
      nil ->
        %AgentStatus{agent_id: agent_id}
        |> AgentStatus.changeset(%{
          "current_task_id" => task_id,
          "purpose" => purpose,
          "application" => application,
          "component" => component,
          "org" => Org.current()
        })
        |> Repo.insert()

      status ->
        status
        |> AgentStatus.changeset(%{
          "current_task_id" => task_id,
          "purpose" => purpose,
          "application" => application,
          "component" => component,
          "org" => Org.current()
        })
        |> Repo.update()
    end
    |> case do
      {:ok, s} -> Cache.put_agent_status(agent_id, to_agent_status_map(s))
      _ -> :ok
    end
  end

  defp clear_agent_status(agent_id) do
    case Repo.get_by(AgentStatus, agent_id: agent_id, org: Org.current()) do
      nil ->
        :ok

      status ->
        case Repo.delete(status) do
          {:ok, _} ->
            Cache.delete_agent_status(agent_id)
            :ok

          {:error, _} ->
            Logger.warning(
              "[Acs] Failed to clear agent status for #{agent_id}, still cleaning cache"
            )

            Cache.delete_agent_status(agent_id)
            {:error, :db_delete_failed}
        end
    end
  end

  defp check_no_duplicate_title(title) when is_binary(title) do
    import Ecto.Query
    org = Org.current()

    case Repo.one(
           from(t in Acs.Acs.Task,
             where: fragment("LOWER(?)", t.title) == ^String.downcase(title),
             where: t.status not in ^["done"],
             where: t.org == ^org,
             limit: 1
           )
         ) do
      nil ->
        :ok

      existing ->
        {:error, "A task with the title '#{title}' already exists (status: #{existing.status})"}
    end
  end

  defp to_task_map(%AcsTask{} = t) do
    %{
      id: t.id,
      slug: t.slug,
      title: t.title,
      description: t.description,
      status: t.status,
      kind: t.kind || "coordination",
      assignee: t.assignee,
      due_at: t.due_at,
      remind_at: t.remind_at,
      authority_sort_order: t.authority_sort_order,
      created_by_agent: t.created_by_agent,
      locked_by_agent: t.locked_by_agent,
      locked_at: t.locked_at,
      auto_release_at: t.auto_release_at,
      inserted_at: t.inserted_at,
      event_count: t.event_count,
      file_paths: t.file_paths || [],
      repo: t.repo,
      org: t.org
    }
  end

  defp to_file_lock_map(%FileLock{} = l) do
    %{
      id: l.id,
      file_path: l.file_path,
      locked_by_agent: l.locked_by_agent,
      locked_at: l.locked_at,
      auto_release_at: l.auto_release_at,
      task_id: l.task_id,
      org: l.org
    }
  end

  defp to_agent_status_map(%AgentStatus{} = s) do
    %{
      agent_id: s.agent_id,
      current_task_id: s.current_task_id,
      purpose: s.purpose,
      application: s.application,
      component: s.component,
      org: s.org
    }
  end

  defp guidance_abac_opts(opts, agent_id, base) when is_list(opts) and is_list(base) do
    base
    |> Keyword.put(:agent_id, agent_id)
    |> then(fn o ->
      case Keyword.get(opts, :agent_role) do
        role when is_binary(role) and role != "" -> Keyword.put(o, :agent_role, role)
        _ -> o
      end
    end)
    |> then(fn o ->
      case Keyword.get(opts, :authority_sort_order) do
        order when is_integer(order) -> Keyword.put(o, :authority_sort_order, order)
        _ -> o
      end
    end)
    |> then(fn o ->
      case Keyword.get(opts, :authority_level_slug) do
        slug when is_binary(slug) and slug != "" -> Keyword.put(o, :authority_level_slug, slug)
        _ -> o
      end
    end)
    |> then(fn o ->
      case Keyword.get(opts, :allowed_teams) do
        teams when is_list(teams) -> Keyword.put(o, :allowed_teams, teams)
        _ -> o
      end
    end)
    |> then(fn o ->
      case Keyword.get(opts, :allowed_projects) do
        projects when is_list(projects) -> Keyword.put(o, :allowed_projects, projects)
        _ -> o
      end
    end)
  end

  @doc """
  Generates a unique, URL-safe slug for a task title within an org.
  Matches the backfill logic in the add_slug_to_acs_tasks migration.
  """
  def unique_slug(title, org) when is_binary(title) do
    base = slugify(title)

    existing =
      Repo.all(
        from t in AcsTask,
          where: t.org == ^org,
          select: t.slug
      )

    unique_slug_for(base, existing)
  end

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
    |> case do
      "" -> "task"
      slug -> slug
    end
  end

  defp unique_slug_for(base, existing) do
    if base in existing, do: unique_slug_for(base, existing, 2), else: base
  end

  defp unique_slug_for(base, existing, n) do
    candidate = "#{base}-#{n}"

    if candidate in existing,
      do: unique_slug_for(base, existing, n + 1),
      else: candidate
  end

  @doc """
  Updates agent application and component context.
  """
  def update_agent_context(agent_id, application, component, purpose \\ nil) do
    case Repo.get_by(AgentStatus, agent_id: agent_id, org: Org.current()) do
      nil ->
        %AgentStatus{agent_id: agent_id}
        |> AgentStatus.changeset(%{
          "application" => application,
          "component" => component,
          "purpose" => purpose,
          "org" => Org.current()
        })
        |> Repo.insert()

      status ->
        status
        |> AgentStatus.changeset(%{
          "application" => application,
          "component" => component,
          "purpose" => purpose || status.purpose,
          "org" => Org.current()
        })
        |> Repo.update()
    end
    |> case do
      {:ok, s} -> Cache.put_agent_status(agent_id, to_agent_status_map(s))
      _ -> :ok
    end
  end
end

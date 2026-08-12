defmodule Acs.Acs.Cache do
  @moduledoc """
  ETS cache layer for ACS (Agent Coordination System).
  """

  require Logger
  alias Acs.Observability.CacheOps
  alias Acs.Repo
  import Ecto.Query, only: [from: 2]

  @tasks_table :acs_tasks
  @file_locks_table :acs_file_locks
  @agent_status_table :acs_agent_status

  @agent_names [
    "Alice",
    "Bob",
    "Carol",
    "David",
    "Eve",
    "Frank",
    "Grace",
    "Henry",
    "Ivy",
    "Jack",
    "Kate",
    "Leo",
    "Mia",
    "Noah",
    "Olivia",
    "Paul",
    "Quinn",
    "Ruby",
    "Sam",
    "Tina",
    "Deepu",
    "Victor",
    "Wendy",
    "Xander",
    "Yara",
    "Zoe",
    "Alex",
    "Bella",
    "Chris",
    "Diana"
  ]
  @next_agent_table :acs_next_agent
  @agent_index_file "priv/acs_next_agent.txt"
  @time_offset_file "priv/acs_time_offset.txt"
  @time_offset_table :acs_time_offset

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_tables()
    load_time_offset()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  @doc """
  Stale agent sweeper — runs every 30s.
  Removes ANY agent (purpose: "active", "sleeping", "working on task")
  that hasn't made a tool call in >60s (updated_at stale).
  Cleans both ETS cache and DB. Agents re-register on next tool call.

  Scans **all orgs** — Cache GenServer has no tenant Org.current(), so
  filtering by default would leave other tenants' ghosts forever (e.g. safetyconnect).
  """
  def handle_info(:sweep_stale_agents, state) do
    Repo.transaction(fn ->
      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      # ponytail: full ETS scan every 30s; ceiling is tens of agents per tenant
      statuses = get_all_agent_statuses(:all)

      stale =
        Enum.filter(statuses, fn s ->
          case s[:updated_at] do
            nil -> true
            dt -> DateTime.compare(dt, cutoff) == :lt
          end
        end)

      Enum.each(stale, fn s ->
        :ets.delete(@agent_status_table, {s.org, s.agent_id})

        Repo.delete_all(
          from(t in Acs.Acs.AgentStatus,
            where: t.agent_id == ^s.agent_id and t.org == ^s.org
          )
        )
      end)

      if stale != [],
        do: Logger.info("[Acs.Cache] Sweep: removed #{length(stale)} stale agents")
    end)

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_stale_agents, 30_000)
  end

  @doc """
  Warms up ETS cache from database after server restart.
  Called from Application.start after supervisor tree is ready.
  """
  def warmup do
    warmup_agent_statuses()
    warmup_tasks()
    warmup_file_locks()
  end

  defp warmup_agent_statuses do
    ensure_table(@agent_status_table)

    statuses = Acs.Repo.all(Acs.Acs.AgentStatus)

    Enum.each(statuses, fn s ->
      map = %{
        agent_id: s.agent_id,
        current_task_id: s.current_task_id,
        purpose: s.purpose,
        application: s.application,
        component: s.component,
        org: s.org,
        updated_at: s.updated_at
      }

      :ets.insert(@agent_status_table, {{s.org, s.agent_id}, map})
    end)

    if statuses != [],
      do: Logger.info("[Acs.Cache] Warmup: loaded #{length(statuses)} agent statuses from DB")
  end

  defp warmup_tasks do
    ensure_table(@tasks_table)

    tasks = Acs.Repo.all(Acs.Acs.Task)

    Enum.each(tasks, fn t ->
      map = %{
        id: t.id,
        title: t.title,
        description: t.description,
        status: t.status,
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

      :ets.insert(@tasks_table, {{t.org, t.id}, map})
    end)

    if tasks != [],
      do: Logger.info("[Acs.Cache] Warmup: loaded #{length(tasks)} tasks from DB")
  end

  defp warmup_file_locks do
    ensure_table(@file_locks_table)

    locks = Acs.Repo.all(Acs.Acs.FileLock)

    Enum.each(locks, fn l ->
      map = %{
        id: l.id,
        file_path: l.file_path,
        locked_by_agent: l.locked_by_agent,
        locked_at: l.locked_at,
        auto_release_at: l.auto_release_at,
        task_id: l.task_id,
        org: l.org
      }

      :ets.insert(@file_locks_table, {{l.org, l.file_path}, map})
    end)

    if locks != [],
      do: Logger.info("[Acs.Cache] Warmup: loaded #{length(locks)} file locks from DB")
  end

  defp load_time_offset do
    ensure_table(@time_offset_table)

    offset =
      case File.read(@time_offset_file) do
        {:ok, content} ->
          case Integer.parse(String.trim(content)) do
            {n, _} when is_integer(n) -> n
            _ -> 0
          end

        _ ->
          0
      end

    :ets.insert(@time_offset_table, {:offset, offset})
    Logger.info("[Acs.Cache] Loaded time offset: #{offset} seconds")
  end

  defp ensure_tables do
    ensure_table(@tasks_table)
    ensure_table(@file_locks_table)
    ensure_table(@agent_status_table)
    ensure_table(@next_agent_table)
  end

  defp ensure_table(name) do
    case :ets.info(name, :name) do
      :undefined ->
        :ets.new(name, [
          :set,
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end
  end

  defp table_exists?(name) when is_atom(name) do
    :ets.info(name, :name) != :undefined
  end

  defp table_exists?(_name), do: false

  # Task operations
  def get_task(task_id, org \\ Acs.Org.current()) do
    ensure_table(@tasks_table)
    key = {org, task_id}

    case :ets.lookup(@tasks_table, key) do
      [{^key, task}] ->
        CacheOps.log(cache_name: @tasks_table, result: "hit", org: org)
        {:ok, task}

      [] ->
        CacheOps.log(cache_name: @tasks_table, result: "miss", org: org)
        {:ok, nil}
    end
  end

  def put_task(task_id, task_map) do
    ensure_table(@tasks_table)
    org = Map.get(task_map, :org) || Acs.Org.current()
    :ets.insert(@tasks_table, {{org, task_id}, Map.put(task_map, :org, org)})
    :ok
  end

  def delete_task(task_id, org \\ Acs.Org.current()) do
    ensure_table(@tasks_table)
    :ets.delete(@tasks_table, {org, task_id})
    :ok
  end

  def get_all_tasks(org \\ Acs.Org.current()) do
    if table_exists?(@tasks_table) do
      :ets.tab2list(@tasks_table)
      |> Enum.map(fn {_, task} -> task end)
      |> Enum.filter(&(&1.org == org))
    else
      []
    end
  end

  def get_tasks_by_status(status, org \\ Acs.Org.current()) do
    get_all_tasks(org) |> Enum.filter(fn t -> t.status == status end)
  end

  # File lock operations
  def get_file_lock(file_path, org \\ Acs.Org.current()) do
    ensure_table(@file_locks_table)
    key = {org, file_path}

    case :ets.lookup(@file_locks_table, key) do
      [{^key, lock}] ->
        CacheOps.log(cache_name: @file_locks_table, result: "hit", org: org)
        {:ok, lock}

      [] ->
        CacheOps.log(cache_name: @file_locks_table, result: "miss", org: org)
        {:ok, nil}
    end
  end

  def put_file_lock(file_path, lock_map, org \\ nil)

  def put_file_lock(file_path, lock_map, org) when is_binary(org) do
    ensure_table(@file_locks_table)
    :ets.insert(@file_locks_table, {{org, file_path}, Map.put(lock_map, :org, org)})
    :ok
  end

  def put_file_lock(file_path, lock_map, nil) do
    ensure_table(@file_locks_table)
    org = Map.get(lock_map, :org) || Acs.Org.current()
    :ets.insert(@file_locks_table, {{org, file_path}, lock_map})
    :ok
  end

  def delete_file_lock(file_path, org \\ Acs.Org.current()) do
    ensure_table(@file_locks_table)
    :ets.delete(@file_locks_table, {org, file_path})
    :ok
  end

  def get_all_file_locks(org \\ Acs.Org.current()) do
    ensure_table(@file_locks_table)

    :ets.tab2list(@file_locks_table)
    |> Enum.map(fn {_, lock} -> lock end)
    |> Enum.filter(&(&1.org == org))
  end

  def get_file_locks_for_task(task_id, org \\ Acs.Org.current()) do
    ensure_table(@file_locks_table)
    get_all_file_locks(org) |> Enum.filter(fn l -> l.task_id == task_id end)
  end

  def get_agent_status(agent_id, org \\ Acs.Org.current()) do
    key = {org, agent_id}

    case :ets.lookup(@agent_status_table, key) do
      [{^key, status}] ->
        CacheOps.log(cache_name: @agent_status_table, result: "hit", org: org)
        {:ok, status}

      [] ->
        CacheOps.log(cache_name: @agent_status_table, result: "miss", org: org)
        {:ok, nil}
    end
  end

  @doc """
  Stores agent status in ETS cache with `updated_at` timestamp.
  Updates DB separately via `Acs.Acs.put_agent_status/2` — this is the ETS-only layer.
  """
  def put_agent_status(agent_id, status_map) do
    org = Map.get(status_map, :org) || Acs.Org.current()

    status_map_with_time =
      status_map
      |> Map.put(:org, org)
      |> Map.put(:updated_at, DateTime.utc_now())

    :ets.insert(@agent_status_table, {{org, agent_id}, status_map_with_time})
    :ok
  end

  def delete_agent_status(agent_id, org \\ Acs.Org.current()) do
    :ets.delete(@agent_status_table, {org, agent_id})
    :ok
  end

  @doc """
  Lightweight heartbeat — updates `updated_at` in ETS only (no DB write).
  Called on every tool call for existing agents to track liveness.
  Returns `:ok` if agent found, `{:ok, nil}` if not found.
  """
  def touch_agent_status(agent_id, org \\ Acs.Org.current()) do
    key = {org, agent_id}

    case :ets.lookup(@agent_status_table, key) do
      [{^key, status}] ->
        CacheOps.log(cache_name: @agent_status_table, result: "hit", org: org)

        :ets.insert(
          @agent_status_table,
          {key, Map.put(status, :updated_at, DateTime.utc_now())}
        )

        :ok

      [] ->
        CacheOps.log(cache_name: @agent_status_table, result: "miss", org: org)
        {:ok, nil}
    end
  end

  def get_all_agent_statuses(org \\ Acs.Org.current())

  def get_all_agent_statuses(:all) do
    :ets.tab2list(@agent_status_table)
    |> Enum.map(fn {{_org, agent_id}, status} -> Map.put(status, :agent_id, agent_id) end)
  end

  def get_all_agent_statuses(org) when is_binary(org) do
    :ets.tab2list(@agent_status_table)
    |> Enum.flat_map(fn
      {{^org, agent_id}, status} -> [Map.put(status, :agent_id, agent_id)]
      _ -> []
    end)
  end

  def get_and_increment_agent_index do
    ensure_table(@next_agent_table)

    # Read current index from persistent storage or ETS
    current_index = read_persistent_index()

    cond do
      current_index == nil ->
        # First time ever - start at 1 (Alice)
        :ets.insert(@next_agent_table, {:next_agent, 2})
        write_persistent_index(2)
        Enum.at(@agent_names, 0)

      current_index >= 30 ->
        # Wrap around to 1
        :ets.insert(@next_agent_table, {:next_agent, 2})
        write_persistent_index(2)
        Enum.at(@agent_names, 0)

      true ->
        # Normal increment
        new_index = current_index + 1
        :ets.insert(@next_agent_table, {:next_agent, new_index})
        write_persistent_index(new_index)
        Enum.at(@agent_names, current_index - 1)
    end
  end

  # File-based persistence helpers
  defp read_persistent_index do
    case File.read(@agent_index_file) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {n, _} when n >= 1 and n <= 30 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp write_persistent_index(n) do
    # Ensure priv directory exists
    Path.dirname(@agent_index_file) |> File.mkdir_p!()
    File.write(@agent_index_file, Integer.to_string(n))
  end

  # Time offset operations
  def get_time_offset do
    ensure_table(@time_offset_table)

    case :ets.lookup(@time_offset_table, :offset) do
      [{:offset, offset}] -> offset
      [] -> 0
    end
  end

  def set_time_offset(seconds) when is_integer(seconds) do
    ensure_table(@time_offset_table)
    :ets.insert(@time_offset_table, {:offset, seconds})
    Logger.info("[Acs.Cache] Set time offset to #{seconds} seconds")
    :ok
  end
end

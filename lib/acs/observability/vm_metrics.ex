defmodule Acs.Observability.VmMetrics do
  @moduledoc """
  Periodically samples BEAM + container/host resource usage into Axiom.

  Ships as structured events on the existing log ingest path (`message == "vm.metrics"`),
  so we avoid a separate OTLP metrics pipeline.

  Fields:
  - BEAM: `memory_*_bytes`, `process_count`, `scheduler_utilization` (0.0–1.0 wall-time)
  - Host/container (best-effort, Linux): `host_memory_*_bytes` from `/proc/meminfo`,
    `cgroup_memory_*_bytes` + `cgroup_cpu_utilization` from the process cgroup

  Full bare-metal host telemetry (all processes, disk, NICs) still needs a host agent
  (e.g. node_exporter / Axiom collector). Inside Docker, cgroup stats are the useful
  "machine" signal for this container.
  """

  use GenServer

  alias Acs.Observability.AxiomLogExporter

  @default_interval_ms 30_000

  @default_jump_thresholds [
    %{metric: "scheduler_utilization", type: :delta, threshold: 0.5},
    %{metric: "cgroup_cpu_utilization", type: :delta, threshold: 0.8},
    %{metric: "memory_total_bytes", type: :pct, threshold: 20.0},
    %{metric: "memory_processes_bytes", type: :pct, threshold: 50.0},
    %{metric: "process_count", type: :pct, threshold: 50.0}
  ]

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def sample(prev \\ nil) do
    prev = normalize_prev(prev)
    memory = :erlang.memory()
    schedulers = scheduler_wall_time()
    utilization = scheduler_utilization(prev.schedulers, schedulers)
    {host_fields, host_prev} = host_sample(prev.host)

    event =
      %{
        "_time" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
        "message" => "vm.metrics",
        "event" => "vm.metrics",
        "level" => "info",
        "severity" => "INFO",
        "service" => "steward_acs",
        "module" => "Acs.Observability.VmMetrics",
        "memory_total_bytes" => memory[:total],
        "memory_processes_bytes" => memory[:processes],
        "memory_system_bytes" => memory[:system],
        "memory_binary_bytes" => memory[:binary],
        "memory_ets_bytes" => memory[:ets],
        "process_count" => :erlang.system_info(:process_count),
        "atom_count" => :erlang.system_info(:atom_count),
        "scheduler_utilization" => utilization
      }
      |> Map.merge(host_fields)

    {event, %{schedulers: schedulers, host: host_prev, event: event}}
  end

  @doc false
  def jump_config do
    Application.get_env(:steward_acs, :vm_jump_thresholds, @default_jump_thresholds)
  end

  @doc false
  def jump_events(prev_event, event, config \\ jump_config())
      when is_map(event) and is_list(config) do
    Enum.flat_map(config, fn %{metric: metric, type: type, threshold: threshold} ->
      case jump(type, threshold, prev_event && prev_event[metric], event[metric]) do
        nil -> []
        info -> [build_jump_event(metric, type, threshold, info, event)]
      end
    end)
  end

  defp jump(:delta, threshold, prev, curr)
       when is_number(prev) and is_number(curr) and abs(curr - prev) >= threshold do
    %{delta: curr - prev, value: curr, prev_value: prev}
  end

  defp jump(:pct, threshold, prev, curr)
       when is_number(prev) and is_number(curr) and prev != 0 do
    pct = abs(curr - prev) / abs(prev) * 100

    if pct >= threshold,
      do: %{delta: curr - prev, pct_change: pct, value: curr, prev_value: prev}
  end

  defp jump(_type, _threshold, _prev, _curr), do: nil

  defp build_jump_event(metric, type, threshold, info, event) do
    %{
      "_time" => event["_time"],
      "message" => "vm.jump",
      "event" => "vm.jump",
      "level" => "warning",
      "severity" => "WARN",
      "service" => "steward_acs",
      "module" => "Acs.Observability.VmMetrics",
      "metric" => metric,
      "jump_type" => type,
      "threshold" => threshold,
      "value" => info.value,
      "prev_value" => info.prev_value,
      "delta" => info.delta
    }
    |> maybe_put("pct_change", info[:pct_change])
  end

  @impl true
  def init(opts) do
    # Required before statistics(:scheduler_wall_time) returns useful diffs.
    _ = :erlang.system_flag(:scheduler_wall_time, true)

    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    exporter = Keyword.get(opts, :exporter, AxiomLogExporter)
    jump_config = Keyword.get(opts, :jump_config, jump_config())

    state = %{
      interval_ms: interval_ms,
      exporter: exporter,
      jump_config: jump_config,
      prev: %{schedulers: scheduler_wall_time(), host: host_baseline()},
      timer: schedule_tick(interval_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {event, prev} = sample(state.prev)
    _ = enqueue(state.exporter, event)

    for jump <- jump_events(Map.get(state.prev, :event), event, state.jump_config) do
      _ = enqueue(state.exporter, jump)
    end

    {:noreply, %{state | prev: prev, timer: schedule_tick(state.interval_ms)}}
  end

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    :ok
  end

  defp enqueue(exporter, event) when is_atom(exporter) do
    exporter.enqueue(event)
  end

  defp enqueue({mod, fun}, event) when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [event])
  end

  defp enqueue(fun, event) when is_function(fun, 1), do: fun.(event)

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp normalize_prev(nil), do: %{schedulers: nil, host: nil}

  defp normalize_prev(schedulers) when is_list(schedulers),
    do: %{schedulers: schedulers, host: nil}

  defp normalize_prev(%{schedulers: _, host: _, event: _} = prev), do: prev
  defp normalize_prev(%{schedulers: _, host: _} = prev), do: prev
  defp normalize_prev(%{schedulers: schedulers}), do: %{schedulers: schedulers, host: nil}

  defp scheduler_wall_time do
    case :erlang.statistics(:scheduler_wall_time) do
      :undefined -> []
      list when is_list(list) -> Enum.sort(list)
    end
  end

  defp scheduler_utilization(nil, _current), do: 0.0
  defp scheduler_utilization([], _current), do: 0.0
  defp scheduler_utilization(_prev, []), do: 0.0

  defp scheduler_utilization(prev, current) do
    prev_map = Map.new(prev, fn {id, active, total} -> {id, {active, total}} end)

    {active_delta, total_delta} =
      Enum.reduce(current, {0, 0}, fn {id, active, total}, {acc_a, acc_t} ->
        case Map.fetch(prev_map, id) do
          {:ok, {prev_a, prev_t}} ->
            {acc_a + max(active - prev_a, 0), acc_t + max(total - prev_t, 0)}

          :error ->
            {acc_a, acc_t}
        end
      end)

    if total_delta > 0, do: Float.round(active_delta / total_delta, 4), else: 0.0
  end

  defp host_baseline do
    mono = System.monotonic_time(:microsecond)

    case read_cgroup_cpu_usec() do
      {:ok, usec} -> %{cpu_usec: usec, mono_us: mono}
      :error -> %{cpu_usec: nil, mono_us: mono}
    end
  end

  defp host_sample(prev_host) do
    fields =
      %{}
      |> maybe_merge(proc_meminfo())
      |> maybe_merge(cgroup_memory())

    {cpu_fields, next_host} = cgroup_cpu(prev_host)
    {maybe_merge(fields, cpu_fields), next_host}
  end

  defp maybe_merge(map, extra) when map_size(extra) == 0, do: map
  defp maybe_merge(map, extra), do: Map.merge(map, extra)

  defp proc_meminfo do
    case File.read("/proc/meminfo") do
      {:ok, body} ->
        kv =
          body
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line, ~r/:\s+/, parts: 2) do
              [key, rest] ->
                case Integer.parse(rest) do
                  # meminfo values are kB
                  {kb, _} -> Map.put(acc, key, kb * 1024)
                  :error -> acc
                end

              _ ->
                acc
            end
          end)

        %{}
        |> maybe_put("host_memory_total_bytes", kv["MemTotal"])
        |> maybe_put("host_memory_available_bytes", kv["MemAvailable"] || kv["MemFree"])

      {:error, _} ->
        %{}
    end
  end

  defp cgroup_memory do
    case self_cgroup_dir() do
      {:ok, dir} ->
        %{}
        |> maybe_put("cgroup_memory_bytes", read_int_file(Path.join(dir, "memory.current")))
        |> maybe_put_cgroup_max(Path.join(dir, "memory.max"))
        # cgroup v1 fallbacks
        |> maybe_put(
          "cgroup_memory_bytes",
          read_int_file(Path.join(dir, "memory.usage_in_bytes"))
        )
        |> maybe_put(
          "cgroup_memory_max_bytes",
          sanitize_cgroup_limit(read_int_file(Path.join(dir, "memory.limit_in_bytes")))
        )

      :error ->
        %{}
    end
  end

  defp maybe_put_cgroup_max(fields, path) do
    case File.read(path) do
      {:ok, contents} ->
        trimmed = String.trim(contents)

        if trimmed in ["max", ""] do
          fields
        else
          case Integer.parse(trimmed) do
            {n, _} -> Map.put(fields, "cgroup_memory_max_bytes", n)
            :error -> fields
          end
        end

      {:error, _} ->
        fields
    end
  end

  defp cgroup_cpu(nil), do: cgroup_cpu(%{cpu_usec: nil, mono_us: nil})

  defp cgroup_cpu(prev) do
    mono = System.monotonic_time(:microsecond)

    case read_cgroup_cpu_usec() do
      {:ok, usec} ->
        fields =
          case prev do
            %{cpu_usec: prev_usec, mono_us: prev_mono}
            when is_integer(prev_usec) and is_integer(prev_mono) and mono > prev_mono and
                   usec >= prev_usec ->
              # Fraction of one CPU; divide by online schedulers for 0.0–1.0 machine util.
              cpus = max(:erlang.system_info(:logical_processors_available), 1)
              delta_cpu = usec - prev_usec
              delta_wall = mono - prev_mono
              util = delta_cpu / (delta_wall * cpus)
              %{"cgroup_cpu_utilization" => Float.round(min(max(util, 0.0), 1.0), 4)}

            _ ->
              %{}
          end

        {fields, %{cpu_usec: usec, mono_us: mono}}

      :error ->
        {%{}, %{cpu_usec: nil, mono_us: mono}}
    end
  end

  defp read_cgroup_cpu_usec do
    case self_cgroup_dir() do
      {:ok, dir} ->
        # cgroup v2
        with :error <- read_cpu_stat_usage(Path.join(dir, "cpu.stat")),
             # some hosts expose cpu.stat at the cgroup root only
             :error <- read_cpu_stat_usage("/sys/fs/cgroup/cpu.stat"),
             # cgroup v1
             :error <- read_int_file_result(Path.join(dir, "cpuacct.usage")) do
          :error
        end

      :error ->
        read_cpu_stat_usage("/sys/fs/cgroup/cpu.stat")
    end
  end

  defp read_cpu_stat_usage(path) do
    case File.read(path) do
      {:ok, body} ->
        Enum.find_value(String.split(body, "\n", trim: true), :error, fn line ->
          case String.split(line, " ", parts: 2) do
            ["usage_usec", rest] ->
              case Integer.parse(String.trim(rest)) do
                {n, _} -> {:ok, n}
                :error -> nil
              end

            _ ->
              nil
          end
        end) || :error

      {:error, _} ->
        :error
    end
  end

  defp read_int_file_result(path) do
    case read_int_file(path) do
      nil -> :error
      # cgroup v1 cpuacct.usage is nanoseconds
      n -> {:ok, div(n, 1000)}
    end
  end

  defp read_int_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {n, _} -> n
          :error -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put_new(map, key, value)

  # cgroup v1 advertises "no limit" as a huge sentinel near 2^63.
  defp sanitize_cgroup_limit(nil), do: nil
  defp sanitize_cgroup_limit(n) when n > 1_000_000_000_000_000, do: nil
  defp sanitize_cgroup_limit(n), do: n

  defp self_cgroup_dir do
    case File.read("/proc/self/cgroup") do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.find_value(:error, fn line ->
          cond do
            # cgroup v2: "0::/path"
            String.starts_with?(line, "0::") ->
              rel = String.trim_leading(line, "0::")
              dir = Path.join("/sys/fs/cgroup", rel)
              if File.dir?(dir), do: {:ok, dir}, else: {:ok, "/sys/fs/cgroup"}

            # cgroup v1 memory controller
            String.contains?(line, ":memory:") ->
              rel = line |> String.split(":", parts: 3) |> List.last()
              dir = Path.join("/sys/fs/cgroup/memory", rel)
              if File.dir?(dir), do: {:ok, dir}

            true ->
              nil
          end
        end)

      {:error, _} ->
        :error
    end
  end
end

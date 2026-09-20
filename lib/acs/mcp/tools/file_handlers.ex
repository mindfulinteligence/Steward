defmodule Acs.MCP.Tools.FileHandlers do
  @moduledoc """
  Handlers for the `manage_files` MCP tool (upload / download / list).

  Files are org-scoped, optionally attached to a task, capped at 50MB, and
  expire 24 hours after upload. Expired-but-unreaped files are treated as
  not found (no existence leak): every read path checks `expires_at`.

  Simplification: upload enforces `file.org == task.org` at insert time, so
  `list`'s org filter transitively covers task visibility without a join;
  `download` re-verifies the task org with a second sequential query instead
  of a join (defense in depth on a non-hot path).
  """

  import Ecto.Query

  alias Acs.Repo

  @max_file_size 52_428_800
  @ttl_hours 24
  @not_found "file not found or not accessible"

  @doc """
  `manage_files` MCP tool. Dispatches on `args["action"]`:

    * `upload`   — requires `task_id` + `filename`, plus exactly one of
                   `base64` or `file_path`; optional `content_type`.
                   Enforces the 50MB cap before any bytes are written.
    * `download` — requires `file_id`; returns base64 `data` plus metadata.
    * `list`     — optional `task_id` filter; metadata only, no bytes.
  """
  def manage_files(%{"action" => "upload"} = args), do: upload(args)
  def manage_files(%{"action" => "download"} = args), do: download(args)
  def manage_files(%{"action" => "list"} = args), do: list(args)

  def manage_files(%{"action" => other}) do
    {:error, "unknown action #{inspect(other)}; expected upload, download, or list"}
  end

  def manage_files(_args), do: {:error, "missing required argument: action"}

  # --- upload -------------------------------------------------------------

  defp upload(args) do
    org = authenticated_org(args)

    with {:ok, task_id} <- require_task_id(args),
         :ok <- verify_task_access(task_id, org),
         {:ok, filename} <- require_filename(args),
         {:ok, content_type} <- optional_string(args, "content_type"),
         {:ok, bytes} <- read_source(args),
         {:ok, file} <-
           insert_file(org, task_id, filename, content_type, bytes, args["agent_id"]) do
      {:ok,
       %{
         id: file.id,
         filename: file.filename,
         size_bytes: file.size_bytes,
         expires_at: DateTime.to_iso8601(file.expires_at)
       }}
    end
  end

  defp read_source(args) do
    base64 = args["base64"]
    file_path = args["file_path"]

    cond do
      is_binary(base64) and is_binary(file_path) ->
        {:error, "provide either base64 or file_path, not both"}

      is_binary(base64) ->
        upload_from_base64(base64)

      is_binary(file_path) ->
        upload_from_path(file_path)

      true ->
        {:error, "provide exactly one of base64 or file_path"}
    end
  end

  # Decoding allocates the full blob, so checking byte_size on the decoded
  # value guarantees nothing is written (or stored) before the cap passes.
  defp upload_from_base64(base64) do
    case Base.decode64(base64) do
      {:ok, bytes} ->
        case enforce_size_limit(byte_size(bytes)) do
          :ok -> {:ok, bytes}
          {:error, _} = err -> err
        end

      :error ->
        {:error, "base64 is not valid base64"}
    end
  end

  defp upload_from_path(file_path) do
    with {:ok, %File.Stat{size: size}} <- stat_source(file_path),
         :ok <- enforce_size_limit(size),
         {:ok, bytes} <- read_source_file(file_path) do
      # Re-check after read: guards the stat/read size race.
      enforce_size_limit(byte_size(bytes))
      |> case do
        :ok -> {:ok, bytes}
        {:error, _} = err -> err
      end
    end
  end

  defp stat_source(file_path) do
    case File.stat(file_path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, "cannot access file_path: #{format_reason(reason)}"}
    end
  end

  defp read_source_file(file_path) do
    case File.read(file_path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, "cannot read file_path: #{format_reason(reason)}"}
    end
  end

  defp enforce_size_limit(size) when size > @max_file_size do
    {:error, "file exceeds maximum size of #{@max_file_size} bytes (50MB)"}
  end

  defp enforce_size_limit(_size), do: :ok

  defp verify_task_access(task_id, org) do
    with {:ok, uuid} <- cast_uuid(task_id) do
      case Repo.get(Acs.Acs.Task, uuid) do
        nil -> {:error, "task not found or not accessible"}
        task -> if task.org == org, do: :ok, else: {:error, "task not found or not accessible"}
      end
    end
  end

  defp insert_file(org, task_id, filename, content_type, bytes, uploaded_by_agent) do
    safe = Path.basename(filename)
    path = Path.join(file_storage_path(), "#{Ecto.UUID.generate()}_#{safe}")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, @ttl_hours * 3600, :second)

    changeset =
      Acs.Acs.File.changeset(%Acs.Acs.File{}, %{
        org: org,
        filename: safe,
        content_type: content_type,
        size_bytes: byte_size(bytes),
        storage_path: path,
        task_id: task_id,
        expires_at: expires_at,
        uploaded_by_agent: uploaded_by_agent
      })

    case Repo.insert(changeset) do
      {:ok, file} ->
        case write_bytes(path, bytes) do
          :ok ->
            {:ok, file}

          {:error, reason} ->
            Repo.delete(file)
            {:error, "failed to store file: #{format_reason(reason)}"}
        end

      {:error, cs} ->
        {:error, "invalid file: #{inspect(cs.errors)}"}
    end
  end

  defp write_bytes(path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, bytes)
    end
  end

  # --- download -----------------------------------------------------------

  defp download(args) do
    org = authenticated_org(args)

    with {:ok, file_id} <- require_file_id(args),
         {:ok, file} <- fetch_visible_file(file_id, org) do
      case File.read(file.storage_path) do
        {:ok, bytes} ->
          {:ok,
           %{
             id: file.id,
             filename: file.filename,
             content_type: file.content_type,
             size_bytes: file.size_bytes,
             data: Base.encode64(bytes)
           }}

        {:error, _reason} ->
          {:error, @not_found}
      end
    end
  end

  defp fetch_visible_file(file_id, org) do
    with {:ok, uuid} <- cast_uuid(file_id) do
      case Repo.get(Acs.Acs.File, uuid) do
        nil ->
          {:error, @not_found}

        file ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          cond do
            DateTime.compare(file.expires_at, now) != :gt ->
              {:error, @not_found}

            file.org != org ->
              {:error, @not_found}

            file.task_id != nil and not task_visible?(file.task_id, org) ->
              {:error, @not_found}

            true ->
              {:ok, file}
          end
      end
    end
  end

  # Second query instead of a join: upload enforces file.org == task.org, so
  # this is formality kept as defense in depth on a non-hot path.
  defp task_visible?(task_id, org) do
    case Repo.get(Acs.Acs.Task, task_id) do
      nil -> false
      task -> task.org == org
    end
  end

  # --- list ---------------------------------------------------------------

  defp list(args) do
    org = authenticated_org(args)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from f in Acs.Acs.File,
        where: f.org == ^org

    # Upload enforces file.org == task.org, so the org filter already covers
    # task visibility; the task_id clause is just the requested filter.
    query =
      case args["task_id"] do
        tid when is_binary(tid) and tid != "" ->
          case Ecto.UUID.cast(tid) do
            {:ok, uuid} -> from f in query, where: f.task_id == ^uuid
            :error -> from f in query, where: false
          end

        _ ->
          query
      end

    # Expiry filtering happens in Elixir (not SQL): utc_datetime ordering is
    # adapter-dependent on SQLite's text storage, and DateTime.compare here
    # exactly matches the download path's expired-means-not-found semantics.
    files =
      query
      |> Repo.all()
      |> Enum.filter(&(DateTime.compare(&1.expires_at, now) == :gt))

    {:ok,
     %{
       files:
         Enum.map(files, fn f ->
           %{
             id: f.id,
             filename: f.filename,
             content_type: f.content_type,
             size_bytes: f.size_bytes,
             task_id: f.task_id,
             uploaded_by_agent: f.uploaded_by_agent,
             expires_at: DateTime.to_iso8601(f.expires_at)
           }
         end),
       count: length(files)
     }}
  end

  # --- shared helpers -----------------------------------------------------

  defp authenticated_org(args) do
    case Map.get(args, "_auth_org_id") do
      org when is_binary(org) and org != "" -> org
      _ -> Acs.Org.current()
    end
  end

  # Invalid UUIDs collapse into @not_found so callers can't probe ids.
  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, @not_found}
    end
  end

  defp require_task_id(args) do
    case args["task_id"] do
      tid when is_binary(tid) and tid != "" -> {:ok, tid}
      _ -> {:error, "missing or invalid required argument: task_id"}
    end
  end

  defp require_filename(args) do
    case args["filename"] do
      name when is_binary(name) and name != "" -> {:ok, Path.basename(name)}
      _ -> {:error, "missing or invalid required argument: filename"}
    end
  end

  defp require_file_id(args) do
    case args["file_id"] do
      fid when is_binary(fid) and fid != "" -> {:ok, fid}
      _ -> {:error, "missing or invalid required argument: file_id"}
    end
  end

  defp optional_string(args, key) do
    case args[key] do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        {:ok, value}

      other ->
        {:error, "invalid argument #{inspect(key)}: expected string, got #{inspect(other)}"}
    end
  end

  defp file_storage_path do
    Application.get_env(:steward_acs, :file_storage_path, "priv/uploads")
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: to_string(reason)
end

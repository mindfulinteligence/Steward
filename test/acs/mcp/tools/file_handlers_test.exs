defmodule Acs.MCP.Tools.FileHandlersTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.FileHandlers
  alias Acs.Repo

  @max 52_428_800

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "acs_file_handlers_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    original = Application.get_env(:steward_acs, :file_storage_path)
    Application.put_env(:steward_acs, :file_storage_path, tmp)

    on_exit(fn ->
      if original do
        Application.put_env(:steward_acs, :file_storage_path, original)
      else
        Application.delete_env(:steward_acs, :file_storage_path)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "upload" do
    test "success via base64 returns id, filename, size_bytes, expires_at ~24h out" do
      task = create_task("org-a")
      content = "hello file"

      assert {:ok, result} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-a",
                 "action" => "upload",
                 "task_id" => task.id,
                 "filename" => "hello.txt",
                 "content_type" => "text/plain",
                 "base64" => Base.encode64(content)
               })

      assert result.filename == "hello.txt"
      assert result.size_bytes == byte_size(content)
      assert is_binary(result.id)

      {:ok, expires_at, _} = DateTime.from_iso8601(result.expires_at)
      delta = DateTime.diff(expires_at, DateTime.utc_now())
      assert delta >= 86_300 and delta <= 86_400
    end

    test "success via file_path copies server-local file" do
      task = create_task("org-a")
      src = tmp_path("acs_src.txt")
      File.write!(src, "from path")

      assert {:ok, result} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-a",
                 "action" => "upload",
                 "task_id" => task.id,
                 "filename" => "copied.txt",
                 "file_path" => src
               })

      assert result.size_bytes == 9
      File.rm!(src)
    end

    test "rejects base64 over 50MB before writing" do
      task = create_task("org-a")
      too_big = :binary.copy(<<0>>, @max + 1)

      assert {:error, msg} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-a",
                 "action" => "upload",
                 "task_id" => task.id,
                 "filename" => "big.bin",
                 "base64" => Base.encode64(too_big)
               })

      assert msg =~ "maximum size"
    end

    test "rejects file_path over 50MB before reading" do
      task = create_task("org-a")
      src = tmp_path("acs_big.bin")
      File.write!(src, :binary.copy(<<0>>, @max + 1))

      assert {:error, msg} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-a",
                 "action" => "upload",
                 "task_id" => task.id,
                 "filename" => "big.bin",
                 "file_path" => src
               })

      assert msg =~ "maximum size"
      File.rm!(src)
    end

    test "rejects both base64 and file_path" do
      task = create_task("org-a")

      assert {:error, msg} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-a",
                 "action" => "upload",
                 "task_id" => task.id,
                 "filename" => "x.txt",
                 "base64" => Base.encode64("a"),
                 "file_path" => "/tmp/whatever"
               })

      assert msg =~ "not both"
    end

    test "rejects neither base64 nor file_path" do
      task = create_task("org-a")

      assert {:error, msg} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-a",
                 "action" => "upload",
                 "task_id" => task.id,
                 "filename" => "x.txt"
               })

      assert msg =~ "exactly one"
    end

    test "rejects upload to a task in another org" do
      task = create_task("org-b")

      assert {:error, msg} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-a",
                 "action" => "upload",
                 "task_id" => task.id,
                 "filename" => "x.txt",
                 "base64" => Base.encode64("a")
               })

      assert msg =~ "not found or not accessible"
    end
  end

  describe "download" do
    test "roundtrips uploaded content" do
      task = create_task("org-a")

      {:ok, uploaded} =
        FileHandlers.manage_files(%{
          "_auth_org_id" => "org-a",
          "action" => "upload",
          "task_id" => task.id,
          "filename" => "round.txt",
          "content_type" => "text/plain",
          "base64" => Base.encode64("roundtrip")
        })

      assert {:ok, result} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-a",
                 "action" => "download",
                 "file_id" => uploaded.id
               })

      assert Base.decode64!(result.data) == "roundtrip"
      assert result.filename == "round.txt"
      assert result.content_type == "text/plain"
      assert result.size_bytes == 9
    end

    test "expired file returns not found" do
      task = create_task("org-a")
      file = insert_file("org-a", task.id, expires_in: -3600)

      assert {:error, msg} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-a",
                 "action" => "download",
                 "file_id" => file.id
               })

      assert msg =~ "not found or not accessible"
    end

    test "file in another org returns not found" do
      task = create_task("org-b")
      file = insert_file("org-b", task.id, expires_in: 3600)

      assert {:error, msg} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-a",
                 "action" => "download",
                 "file_id" => file.id
               })

      assert msg =~ "not found or not accessible"
    end
  end

  describe "list" do
    test "excludes expired files" do
      task = create_task("org-a")
      _live = insert_file("org-a", task.id, expires_in: 3600, filename: "live.txt")
      _dead = insert_file("org-a", task.id, expires_in: -60, filename: "dead.txt")

      assert {:ok, result} =
               FileHandlers.manage_files(%{"_auth_org_id" => "org-a", "action" => "list"})

      names = Enum.map(result.files, & &1.filename)
      assert "live.txt" in names
      refute "dead.txt" in names
      assert result.count == 1
    end

    test "respects org scoping and task_id filter" do
      task_a = create_task("org-a")
      task_b = create_task("org-b")
      _a = insert_file("org-a", task_a.id, expires_in: 3600, filename: "a.txt")
      _b = insert_file("org-b", task_b.id, expires_in: 3600, filename: "b.txt")

      assert {:ok, result} =
               FileHandlers.manage_files(%{"_auth_org_id" => "org-a", "action" => "list"})

      assert Enum.map(result.files, & &1.filename) == ["a.txt"]

      assert {:ok, filtered} =
               FileHandlers.manage_files(%{
                 "_auth_org_id" => "org-b",
                 "action" => "list",
                 "task_id" => task_b.id
               })

      assert Enum.map(filtered.files, & &1.filename) == ["b.txt"]
    end
  end

  # --- helpers ------------------------------------------------------------

  defp create_task(org) do
    Acs.Org.with_current(org, fn ->
      {:ok, task} = Acs.create_task(%{"title" => "file handlers test task"}, "agent")
      task
    end)
  end

  defp insert_file(org, task_id, opts) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(Keyword.get(opts, :expires_in, 3600))

    filename = Keyword.get(opts, :filename, "f.bin")
    storage_path = Path.join([storage_dir(), "#{Ecto.UUID.generate()}_#{filename}"])

    {:ok, file} =
      Acs.Acs.File.changeset(%Acs.Acs.File{}, %{
        org: org,
        filename: filename,
        size_bytes: 4,
        storage_path: storage_path,
        task_id: task_id,
        expires_at: expires_at
      })
      |> Repo.insert()

    File.write!(file.storage_path, "data")
    file
  end

  defp storage_dir, do: Application.fetch_env!(:steward_acs, :file_storage_path)

  defp tmp_path(name) do
    Path.join(System.tmp_dir!(), "#{name}_#{System.unique_integer([:positive])}")
  end
end

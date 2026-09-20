defmodule Acs.Acs.FileTest do
  use Acs.DataCase, async: false

  alias Acs.Acs.File
  alias Acs.Repo

  @valid_attrs %{
    org: "org-a",
    filename: "report.pdf",
    content_type: "application/pdf",
    size_bytes: 123,
    storage_path: "priv/uploads/abc_report.pdf",
    uploaded_by_agent: "agent-1",
    expires_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(3600)
  }

  test "changeset with valid attributes inserts with binary_id pk" do
    {:ok, file} =
      %File{}
      |> File.changeset(@valid_attrs)
      |> Repo.insert()

    assert file.filename == "report.pdf"
    assert file.org == "org-a"
    assert is_binary(file.id)
    assert byte_size(file.id) == 36
  end

  test "org defaults to 'default'" do
    {:ok, file} =
      %File{}
      |> File.changeset(Map.delete(@valid_attrs, :org))
      |> Repo.insert()

    assert file.org == "default"
  end

  test "changeset requires filename, size_bytes, storage_path, expires_at" do
    errors = errors_on(File.changeset(%File{}, %{org: "org-a"}))

    assert errors[:filename]
    assert errors[:size_bytes]
    assert errors[:storage_path]
    assert errors[:expires_at]

    refute errors[:content_type]
    refute errors[:task_id]
    refute errors[:uploaded_by_agent]
  end

  test "task_id references acs_tasks" do
    task = create_task()

    {:ok, file} =
      %File{}
      |> File.changeset(Map.put(@valid_attrs, :task_id, task.id))
      |> Repo.insert()

    assert file.task_id == task.id
  end

  defp create_task do
    Acs.Org.with_current("org-a", fn ->
      {:ok, task} = Acs.create_task(%{"title" => "file schema test task"}, "agent")
      task
    end)
  end
end

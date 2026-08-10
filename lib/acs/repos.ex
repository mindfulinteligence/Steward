defmodule Acs.Repos do
  @moduledoc """
  Repo identity for multi-repo org knowledge.

  A `repo` is a project / repository name (e.g. `steward_acs`, `acme-web`).
  It is a **declared name**, not inferred from scope paths. Coding agents
  declare their working repo once, on install, in the coding system prompt
  (`Repo: <name>` in `AGENTS_STEWARD.md`), or via the `:coding_repo`
  application env / `ACS_CODING_REPO` env var. `get_started` surfaces the
  resolved repo (or asks the user to add it when missing).

  Rules:
  - `nil` repo = org-wide knowledge (not scoped to any repo).
  - Saves stamp `repo` on memories/skills/specs when known; `nil` otherwise.
  - Retrieval blends current-repo results first, org-wide second, other
    repos last (labeled `repo:` when from a different repo).
  """

  @doc """
  Repo declared in the coding system prompt, if any.

  Same resolution as `AcsWeb.McpUrls.coding_system_prompt/0`: prefers
  repo-root `AGENTS_STEWARD.md`, falls back to
  `priv/prompts/coding_system_prompt.md`. Looks for a `Repo:` line.
  """
  @spec repo_from_prompt() :: String.t() | nil
  def repo_from_prompt do
    prompt =
      [
        Path.join(File.cwd!(), "AGENTS_STEWARD.md"),
        Path.join(:code.priv_dir(:steward_acs), "prompts/coding_system_prompt.md")
      ]
      |> Enum.find_value(&read_prompt/1)

    case prompt do
      content when is_binary(content) -> extract_repo(content)
      _ -> nil
    end
  end

  @doc """
  Repo from configuration (`:steward_acs, :coding_repo` or `ACS_CODING_REPO`).
  """
  @spec configured_repo() :: String.t() | nil
  def configured_repo do
    Application.get_env(:steward_acs, :coding_repo)
    |> case do
      value when is_binary(value) and value != "" -> normalize(value)
      _ -> System.get_env("ACS_CODING_REPO") |> normalize_if_present()
    end
  end

  @doc """
  Effective repo for the current session: prompt declaration wins, then
  config. Returns `nil` when neither is set (org-wide).
  """
  @spec repo() :: String.t() | nil
  def repo do
    repo_from_prompt() || configured_repo()
  end

  @doc """
  Human-readable guidance about the repo for the start call.

  When a repo is declared, explains how saves get tagged. When missing,
  tells the agent to ask the user to add it to `AGENTS_STEWARD.md`.
  """
  @spec guidance() :: String.t()
  def guidance do
    case repo() do
      nil ->
        """
        No repo declared for this session yet. Ask the human to add a `Repo: <name>`
        line (e.g. `Repo: steward_acs`) to the coding system prompt / AGENTS_STEWARD.md
        in this repo (or set ACS_CODING_REPO in the server .env), then restart.
        Until then, knowledge you save is org-wide (repo: nil) and search blends all repos.
        """

      name ->
        "You are working in repo `#{name}`. Knowledge you save is tagged `repo: #{name}`. " <>
          "Search surfaces your repo first, org-wide knowledge second, and other repos " <>
          "last (labeled `repo:` when from a different repo)."
    end
    |> String.trim()
  end

  @doc """
  Normalize a repo name: trim, lowercase, collapse to slug-safe `-`/`_` chars.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> then(&if(&1 == "", do: nil, else: &1))
  end

  @doc """
  Infer repo from a file path, mirroring `Acs.ClaimContext`'s app detection:
  the path segment immediately before `lib/`. Falls back to `nil` (org-wide)
  rather than inventing a repo, unless it is the well-known default app.
  """
  @spec repo_for_file_path(String.t() | nil) :: String.t() | nil
  def repo_for_file_path(path) when is_binary(path) do
    parts = Path.split(path)
    lib_idx = Enum.find_index(parts, &(&1 == "lib"))

    if lib_idx && lib_idx > 0 do
      normalize(Enum.at(parts, lib_idx - 1))
    else
      nil
    end
  end

  def repo_for_file_path(_), do: nil

  @doc """
  Infer repo from a scope path: the first segment, when it looks like a
  project name (not an org/domain like `acme/sales`). Returns `nil` when
  ambiguous — never guess from `scope_path`.
  """
  @spec repo_for_scope(String.t() | nil) :: String.t() | nil
  def repo_for_scope(scope_path) when is_binary(scope_path) do
    case scope_path |> String.split("/") |> List.first() do
      nil -> nil
      first -> normalize(first)
    end
  end

  def repo_for_scope(_), do: nil

  @doc """
  All repo names currently known in the org, union of:
  - `app` values on specs entries
  - `repo` values on memories
  - first scope segment on skills

  Used for diagnostics / `list_repos`; not required for first use.
  """
  @spec list() :: [String.t()]
  def list do
    [spec_apps(), memory_repos(), skill_repos()]
    |> List.flatten()
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp spec_apps do
    Acs.Specs.Loader.load_all()
    |> Enum.map(& &1.app)
    |> Enum.reject(&is_nil/1)
  end

  defp memory_repos do
    {:ok, memories} = Acs.Memory.Indexer.list_memories(%{limit: 1_000})
    Enum.map(memories, & &1.repo)
  rescue
    _ -> []
  end

  defp skill_repos do
    Acs.Skills.Store.list_skills_by_scope("")
    |> Enum.flat_map(& &1.scope_paths)
    |> Enum.map(&repo_for_scope/1)
  rescue
    _ -> []
  end

  defp extract_repo(content) when is_binary(content) do
    case Regex.run(~r/(?im)repo\s*[:=]\s*([a-z0-9][a-z0-9._-]*)/, content,
           capture: :all_but_first
         ) do
      [name | _] -> normalize(name)
      _ -> nil
    end
  end

  defp extract_repo(_), do: nil

  defp normalize_if_present(nil), do: nil
  defp normalize_if_present(""), do: nil
  defp normalize_if_present(value), do: normalize(value)

  defp read_prompt(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> nil
          trimmed -> trimmed
        end

      {:error, _} ->
        nil
    end
  end
end

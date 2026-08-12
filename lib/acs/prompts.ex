defmodule Acs.Prompts do
  @moduledoc """
  Loads prompt and instruction files.

  Single-tenant deployments load editable vault prompts first, followed by
  legacy vault locations and bundled `priv/prompts/`. Multi-tenant deployments
  load per-org database overrides first (see `Acs.Prompts.Store`), then
  bundled `priv/prompts/` files.
  """

  @doc """
  Load a prompt file by category and name (without extension).

  Multi-tenant deployments check for a per-org database override first, then
  fall back to bundled `priv/prompts/` files. Single-tenant deployments load
  editable vault prompts first, followed by legacy vault locations and bundled
  `priv/prompts/`.

  Returns trimmed file content, or `default` when no override or file is found.
  """
  def load(category, name, opts \\ []) when is_binary(category) and is_binary(name) do
    default = Keyword.get(opts, :default, "")

    case database_override(category, name) do
      {:ok, content} -> content
      :none -> load_file(category, name, default)
    end
  end

  defp database_override(category, name) do
    if Acs.Org.multi_tenant?() do
      Acs.Prompts.Store.override(category, name)
    else
      :none
    end
  end

  defp load_file(category, name, default) do
    category
    |> candidate_paths(name)
    |> Enum.find_value(fn path ->
      case File.read(path) do
        {:ok, content} -> String.trim(content)
        _ -> nil
      end
    end) || default
  end

  @doc "Load agent-facing instructions for a category (`skills`, `specs`)."
  def instructions(category), do: load(category, "instructions")

  @doc "Load chat-facing instructions for a category (`skills`, `specs`)."
  def instructions_chat(category), do: load(category, "instructions_chat")

  @doc """
  Load claim-tier instructions (complete + short). Never slice the full file.

  Falls back to `instructions/1` only if no claim file exists.
  """
  def instructions_claim(category), do: load(category, "instructions_claim")

  @doc """
  Load chat claim-tier instructions. Falls back to `instructions_chat/1`.
  """
  def instructions_chat_claim(category), do: load(category, "instructions_chat_claim")

  defp candidate_paths(category, name) do
    if safe_segment?(category) and safe_segment?(name) do
      file = "#{name}.md"
      builtin = Path.join([Application.app_dir(:steward_acs), "priv/prompts"])

      roots =
        if Acs.Org.multi_tenant?() do
          [builtin]
        else
          [Acs.Org.prompts_dir() | Acs.Org.legacy_prompts_dirs() ++ [builtin]]
        end

      roots
      |> Enum.uniq()
      |> Enum.map(fn root -> {root, Path.join([root, category, file])} end)
      |> Enum.filter(fn {root, path} ->
        if root == builtin do
          File.regular?(path)
        else
          Acs.Org.safe_path?(root, path) and
            match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
        end
      end)
      |> Enum.map(&elem(&1, 1))
    else
      []
    end
  end

  defp safe_segment?(segment),
    do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, segment)
end

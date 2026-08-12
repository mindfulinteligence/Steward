defmodule Acs.Prompts.Store do
  import Ecto.Query

  alias Acs.Artifacts.{Ledger, Prompt}
  alias Acs.Orgs.Organization
  alias Acs.Repo

  @status_tombstoned "tombstoned"

  @doc """
  Persist a per-org prompt override through the immutable artifact ledger.

  Appends a new ledger revision and advances the `acs_prompts` projection.
  Returns `{:ok, map}` on success or an error tuple.
  """
  def save_override(category, name, content, opts \\ []) do
    public_id = public_id(category, name)
    snapshot = %{"category" => category, "name" => name, "content" => content}

    Ledger.save(
      :prompt,
      public_id,
      snapshot,
      ledger_opts(opts, name) ++
        [expected_head_revision_id: head_revision_id(category, name)]
    )
  end

  @doc """
  Tombstone a per-org prompt override, restoring builtin behavior.

  Appends a `tombstone` ledger revision; the projection row remains but is
  marked tombstoned and is ignored by `override/2`.
  """
  def tombstone(category, name, opts \\ []) do
    public_id = public_id(category, name)

    snapshot = %{
      "category" => category,
      "name" => name,
      "content" => "",
      "status" => @status_tombstoned
    }

    Ledger.save(
      :prompt,
      public_id,
      snapshot,
      ledger_opts(opts, name) ++
        [operation: "tombstone", expected_head_revision_id: head_revision_id(category, name)]
    )
  end

  @doc """
  Return the active override for a prompt, or `:none`.

  Tombstoned overrides count as no override so the builtin prompt is used.
  """
  def override(category, name) do
    case projection(category, name) do
      %Prompt{status: @status_tombstoned} -> :none
      %Prompt{content: content} -> {:ok, String.trim(content)}
      nil -> :none
    end
  end

  @doc "Return active overrides as `%{category:, name:}` maps."
  def overrides do
    query = from(p in active_projections(), select: %{category: p.category, name: p.name})
    Repo.all(query)
  end

  @doc "Whether an active override exists for a prompt."
  def override_exists?(category, name), do: override(category, name) != :none

  defp ledger_opts(opts, name) do
    defaults = [org: Acs.Org.current(), message: "Save prompt override #{name}"]

    Keyword.merge(
      defaults,
      Keyword.take(opts, [:org, :actor, :source, :message, :request_id, :metadata])
    )
  end

  defp head_revision_id(category, name) do
    case projection(category, name) do
      %Prompt{head_revision_id: id} -> id
      nil -> nil
    end
  end

  defp projection(category, name) do
    Repo.one(
      from p in Prompt,
        join: org in Organization,
        on: org.id == p.organization_id,
        where: org.slug == ^Acs.Org.current() and p.category == ^category and p.name == ^name,
        limit: 1
    )
  end

  defp active_projections do
    from p in Prompt,
      join: org in Organization,
      on: org.id == p.organization_id,
      where:
        org.slug == ^Acs.Org.current() and (p.status != ^@status_tombstoned or is_nil(p.status))
  end

  defp public_id(category, name), do: "#{category}/#{name}"
end

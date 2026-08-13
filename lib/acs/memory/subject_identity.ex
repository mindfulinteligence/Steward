defmodule Acs.Memory.SubjectIdentity do
  @moduledoc """
  Determines whether two memories concern distinct subjects, so that
  near-duplicate detection never blocks a distinct fact that merely shares
  framing (scope/type/summary).

  `about_*` fields are stored as tags with `about-name:`, `about-type:` and
  `about-email:` prefixes. Two memories are a distinct subject when both declare
  a non-empty `about-name` (or `about-type`) and those subjects differ. If either
  side lacks a subject, the gate falls back to "not distinct", letting the
  similarity threshold decide.
  """

  @doc """
  Returns `true` when the two memories are about distinct subjects.
  Accepts either tag lists (new `%Acs.Memory{}.tags`) or `%{tags_json: ...}`
  schema rows (existing memories).
  """
  def distinct_subject?(tags_or_row_a, tags_or_row_b) do
    case {subject(tags_or_row_a), subject(tags_or_row_b)} do
      {{:named, a}, {:named, b}} when a != "" and b != "" -> a != b
      _ -> false
    end
  end

  defp subject(%{tags_json: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, tags} when is_list(tags) -> subject(tags)
      _ -> :none
    end
  end

  defp subject(%{tags: tags}) when is_list(tags), do: subject(tags)

  defp subject(tags) when is_list(tags) do
    name = tag_value(tags, "about-name:")
    type = tag_value(tags, "about-type:")

    case name || type do
      nil -> :none
      "" -> :none
      value -> {:named, value}
    end
  end

  defp subject(_), do: :none

  defp tag_value(tags, prefix) do
    Enum.find_value(tags, fn
      tag when is_binary(tag) and tag != "" ->
        if String.starts_with?(tag, prefix), do: String.trim_leading(tag, prefix), else: nil

      _ ->
        nil
    end)
  end
end

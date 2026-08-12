defmodule Acs.Memory.Intake do
  @moduledoc """
  Pre-save triage for candidate memories.

  LLM classifies entity (person/company), sensitivity, and quality.
  Default allow with a high bar for questions (at most one). Heuristic
  fallback when no LLM providers are available. Soft suggestions never
  block alone; server remains authority for writes.
  """

  require Logger

  alias Acs.LLM

  @sensitive_patterns [
    ~r/\b(?:revenue|ARR|MRR|EBITDA|valuation)\b/i,
    ~r/\$\s?\d[\d,]*(?:\.\d+)?\s*(?:m|mm|million|b|bn|billion|k)?\b/i,
    ~r/\b(?:password|api[_ ]?key|secret|ssn|social security)\b/i,
    ~r/\b(?:bank account|routing number|wire details)\b/i,
    ~r/\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/,
    ~r/\b(?:salary|compensation|bonus)\b/i
  ]

  @type review :: %{
          about_type: String.t() | nil,
          about_name: String.t() | nil,
          about_email: String.t() | nil,
          suggested_sensitive: boolean(),
          suggested_visibility: String.t() | nil,
          suggested_title: String.t() | nil,
          suggested_kind: String.t() | nil,
          is_eternal_truth: boolean(),
          questions: [map()],
          notes: String.t() | nil,
          source: :llm | :heuristic
        }

  @doc """
  Review a candidate memory map (string keys from MCP args).

  Returns `{:ok, review}`. Always succeeds — falls back to heuristics if LLM fails.
  """
  @spec review(map()) :: {:ok, review()}
  def review(candidate) when is_map(candidate) do
    heuristic = heuristic_review(candidate)

    if Application.get_env(:steward_acs, :memory_intake_llm, true) == false do
      {:ok, heuristic}
    else
      case LLM.intake_classify(candidate) do
        {:ok, decoded, meta} ->
          {:ok, merge_reviews(heuristic, normalize_llm_review(decoded), meta)}

        {:error, reason} ->
          Logger.info("[Memory.Intake] LLM unavailable (#{inspect(reason)}); using heuristics")
          {:ok, heuristic}
      end
    end
  end

  @doc "Cheap offline triage used as baseline and LLM fallback."
  def heuristic_review(candidate) when is_map(candidate) do
    title = blank_to_nil(candidate["title"]) || ""
    content = blank_to_nil(candidate["content"]) || ""
    text = title <> "\n" <> content

    about_type = normalize_about_type(candidate["about_type"])
    about_name = blank_to_nil(candidate["about_name"])
    about_email = blank_to_nil(candidate["about_email"])
    visibility = blank_to_nil(candidate["visibility"])
    confidential? = truthy?(candidate["confidential"])

    suggested_sensitive = Enum.any?(@sensitive_patterns, &Regex.match?(&1, text))

    questions =
      []
      |> maybe_scope_question(about_type, about_name, about_email, visibility, confidential?)
      |> maybe_sensitive_question(suggested_sensitive, visibility, confidential?)

    %{
      about_type: about_type,
      about_name: about_name,
      about_email: about_email,
      suggested_sensitive: suggested_sensitive,
      suggested_visibility:
        cond do
          confidential? -> "personal"
          suggested_sensitive -> "personal"
          true -> nil
        end,
      suggested_title: nil,
      suggested_kind: nil,
      is_eternal_truth: true,
      questions: questions,
      notes:
        if(suggested_sensitive,
          do: "Heuristic: content may be sensitive",
          else: nil
        ),
      source: :heuristic
    }
  end

  defp maybe_scope_question(qs, about_type, about_name, about_email, visibility, confidential?) do
    if about_entity?(about_type, about_name, about_email) and is_nil(visibility) and
         not confidential? do
      [
        %{
          "id" => "scope",
          "prompt" =>
            "This memory is about a #{about_type || "entity"}. At what level should it be scoped?",
          "options" => scope_options()
        }
        | qs
      ]
    else
      qs
    end
  end

  defp maybe_sensitive_question(qs, suggested_sensitive, visibility, confidential?) do
    if suggested_sensitive and (is_nil(visibility) or visibility == "org") and not confidential? do
      [
        %{
          "id" => "sensitive",
          "prompt" =>
            "This looks sensitive (numbers/secrets/PII). Keep as saved, or switch to personal?",
          "options" => [
            %{"visibility" => "personal", "label" => "Personal — only the saver"},
            %{"visibility" => "org", "label" => "Keep org-visible"}
          ]
        }
        | qs
      ]
    else
      qs
    end
  end

  defp normalize_llm_review(decoded) when is_map(decoded) do
    questions =
      case Map.get(decoded, "questions") do
        list when is_list(list) -> list |> Enum.filter(&is_map/1) |> Enum.take(1)
        _ -> []
      end

    %{
      about_type: normalize_about_type(Map.get(decoded, "about_type")),
      about_name: blank_to_nil(Map.get(decoded, "about_name")),
      about_email: blank_to_nil(Map.get(decoded, "about_email")),
      suggested_sensitive: truthy?(Map.get(decoded, "suggested_sensitive")),
      suggested_visibility: normalize_visibility(Map.get(decoded, "suggested_visibility")),
      suggested_title: blank_to_nil(Map.get(decoded, "suggested_title")),
      suggested_kind: blank_to_nil(Map.get(decoded, "suggested_kind")),
      is_eternal_truth: Map.get(decoded, "is_eternal_truth", true) != false,
      questions: questions,
      notes: blank_to_nil(Map.get(decoded, "notes")),
      source: :llm
    }
  end

  defp merge_reviews(heuristic, llm, meta) do
    %{
      about_type: llm.about_type || heuristic.about_type,
      about_name: llm.about_name || heuristic.about_name,
      about_email: llm.about_email || heuristic.about_email,
      suggested_sensitive: llm.suggested_sensitive or heuristic.suggested_sensitive,
      suggested_visibility: llm.suggested_visibility || heuristic.suggested_visibility,
      suggested_title: llm.suggested_title,
      suggested_kind: llm.suggested_kind,
      is_eternal_truth: llm.is_eternal_truth,
      questions: merge_questions(heuristic.questions, llm.questions),
      notes: llm.notes || heuristic.notes,
      source: :llm,
      provider: Map.get(meta, :provider),
      model: Map.get(meta, :model)
    }
  end

  defp merge_questions(heuristic_qs, llm_qs) do
    ids = MapSet.new(Enum.map(llm_qs, & &1["id"]))
    kept = Enum.reject(heuristic_qs, fn q -> MapSet.member?(ids, q["id"]) end)
    (llm_qs ++ kept) |> Enum.take(1)
  end

  defp about_entity?(type, name, email),
    do: not is_nil(type) or not is_nil(name) or not is_nil(email)

  defp scope_options do
    [
      %{"visibility" => "org", "label" => "Org — everyone in the organization"},
      %{"visibility" => "team", "label" => "Team — pass team: as well"},
      %{"visibility" => "project", "label" => "Project — pass project: as well"},
      %{"visibility" => "personal", "label" => "Personal — only the saver"}
    ]
  end

  defp normalize_about_type("person"), do: "person"
  defp normalize_about_type("company"), do: "company"
  defp normalize_about_type(_), do: nil

  defp normalize_visibility(v) when v in ~w(org team project personal), do: v
  defp normalize_visibility(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("yes"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    t = String.trim(s)
    if t == "", do: nil, else: t
  end

  defp blank_to_nil(_), do: nil
end

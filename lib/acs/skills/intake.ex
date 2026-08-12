defmodule Acs.Skills.Intake do
  @moduledoc """
  Pre-save triage for candidate skills.

  Single-pass: one LLM classification (or heuristics). Default allow.
  High bar for questions — only block on secrets, unusable/unclear content,
  or skills with no followable steps. Soft suggestions never block alone.
  """

  require Logger

  alias Acs.LLM

  # Secrets only — mentions of "rotate secrets" / Infisical are fine.
  @secret_patterns [
    ~r/\b(?:password|passwd|api[_ -]?key|secret[_ -]?key|private[_ -]?key)\s*[:=]\s*\S+/i,
    ~r/\b(?:Bearer|sk-|acs_dev_|ghp_|xox[baprs]-)[A-Za-z0-9_\-]{8,}/,
    ~r/\b-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/
  ]

  @type review :: %{
          allow: boolean(),
          suggested_sensitive: boolean(),
          needs_improvement: boolean(),
          suggested_description: String.t() | nil,
          suggested_when_to_use: String.t() | nil,
          questions: [map()],
          notes: String.t() | nil,
          source: :llm | :heuristic
        }

  @doc """
  Review a candidate skill map (string keys from MCP args).

  Always succeeds — falls back to heuristics if LLM is down or disabled.
  """
  @spec review(map()) :: {:ok, review()}
  def review(candidate) when is_map(candidate) do
    heuristic = heuristic_review(candidate)

    if Application.get_env(:steward_acs, :skill_intake_llm, true) == false do
      {:ok, heuristic}
    else
      case LLM.skill_intake_classify(candidate) do
        {:ok, decoded, meta} ->
          {:ok, merge_reviews(heuristic, normalize_llm_review(decoded), meta)}

        {:error, reason} ->
          Logger.info("[Skills.Intake] LLM unavailable (#{inspect(reason)}); using heuristics")
          {:ok, heuristic}
      end
    end
  end

  @doc "Cheap offline triage used as baseline and LLM fallback."
  def heuristic_review(candidate) when is_map(candidate) do
    content = blank_to_nil(candidate["content"]) || ""
    name = blank_to_nil(candidate["name"]) || ""
    text = name <> "\n" <> content

    suggested_sensitive = Enum.any?(@secret_patterns, &Regex.match?(&1, text))
    has_steps? = has_followable_steps?(content)
    too_thin? = String.length(String.trim(content)) < 120 and not has_steps?

    questions =
      []
      |> maybe_secret_question(suggested_sensitive)
      |> maybe_quality_question(too_thin? and not suggested_sensitive)

    %{
      allow: questions == [],
      suggested_sensitive: suggested_sensitive,
      needs_improvement: too_thin?,
      suggested_description: nil,
      suggested_when_to_use: nil,
      questions: Enum.take(questions, 1),
      notes:
        cond do
          suggested_sensitive -> "Heuristic: skill body looks like it embeds a secret"
          too_thin? -> "Heuristic: skill needs clear numbered steps"
          true -> nil
        end,
      source: :heuristic
    }
  end

  defp maybe_secret_question(qs, true) do
    [
      %{
        "id" => "sensitive",
        "prompt" =>
          "This skill looks like it embeds a secret/credential. Redact it (reference a vault/env var instead), then retry skill_save.",
        "options" => [
          %{"action" => "redact", "label" => "I'll redact and retry"},
          %{"action" => "confirm", "label" => "False positive — save with intake_confirmed: true"}
        ]
      }
      | qs
    ]
  end

  defp maybe_secret_question(qs, false), do: qs

  defp maybe_quality_question(qs, true) do
    [
      %{
        "id" => "needs_improvement",
        "prompt" =>
          "This does not look like a followable procedure. Add numbered steps (and usually prerequisites/verification), or use save_memory for a one-line truth.",
        "options" => [
          %{"action" => "improve", "label" => "I'll add steps and retry"},
          %{"action" => "confirm", "label" => "Save as-is with intake_confirmed: true"}
        ]
      }
      | qs
    ]
  end

  defp maybe_quality_question(qs, false), do: qs

  defp has_followable_steps?(content) do
    Regex.match?(~r/(?m)^\s*(?:\d+[\.\)]\s+|[-*]\s+\*\*|##\s*steps?\b)/i, content) or
      Regex.match?(~r/\b(?:step\s*1|first[,:], then)\b/i, content)
  end

  defp normalize_llm_review(decoded) when is_map(decoded) do
    questions =
      case Map.get(decoded, "questions") do
        list when is_list(list) -> list |> Enum.filter(&is_map/1) |> Enum.take(1)
        _ -> []
      end

    allow? = Map.get(decoded, "allow", true) != false and questions == []

    %{
      allow: allow?,
      suggested_sensitive: truthy?(Map.get(decoded, "suggested_sensitive")),
      needs_improvement: truthy?(Map.get(decoded, "needs_improvement")),
      suggested_description: blank_to_nil(Map.get(decoded, "suggested_description")),
      suggested_when_to_use: blank_to_nil(Map.get(decoded, "suggested_when_to_use")),
      questions: questions,
      notes: blank_to_nil(Map.get(decoded, "notes")),
      source: :llm
    }
  end

  defp merge_reviews(heuristic, llm, meta) do
    questions = merge_questions(heuristic.questions, llm.questions)

    %{
      allow: questions == [] and llm.allow != false,
      suggested_sensitive: llm.suggested_sensitive or heuristic.suggested_sensitive,
      needs_improvement: llm.needs_improvement or heuristic.needs_improvement,
      suggested_description: llm.suggested_description,
      suggested_when_to_use: llm.suggested_when_to_use,
      questions: questions,
      notes: llm.notes || heuristic.notes,
      source: :llm,
      provider: Map.get(meta, :provider),
      model: Map.get(meta, :model)
    }
  end

  defp merge_questions(heuristic_qs, llm_qs) do
    # Prefer LLM wording; keep heuristic only if LLM asked nothing but heuristic is blocking.
    cond do
      llm_qs != [] -> Enum.take(llm_qs, 1)
      heuristic_qs != [] -> Enum.take(heuristic_qs, 1)
      true -> []
    end
  end

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

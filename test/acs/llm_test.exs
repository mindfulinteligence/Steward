defmodule Acs.LLMTest do
  use ExUnit.Case, async: true

  alias Acs.LLM

  describe "extract_json_content/1" do
    test "returns decoded map for valid JSON" do
      content =
        ~S({"quality_score": 4, "title_quality": 5, "is_noise": false, "recommendation": "approve", "reasoning": "Good memory entry.", "improvements": "None", "suggested_title": "Test title", "is_duplicate_of": null})

      assert {:ok, decoded} = LLM.extract_json_content(content)
      assert decoded["recommendation"] == "approve"
      assert decoded["is_duplicate_of"] == nil
    end

    test "handles JSON with nested objects correctly" do
      content = ~S({"level1": {"level2": {"value": 42}}, "recommendation": "approve"})
      assert {:ok, decoded} = LLM.extract_json_content(content)
      assert decoded["recommendation"] == "approve"
    end

    test "extracts JSON from markdown code blocks" do
      content = """
      Here is the evaluation:
      ```json
      {"quality_score": 5, "recommendation": "approve"}
      ```
      """

      assert {:ok, decoded} = LLM.extract_json_content(content)
      assert decoded["quality_score"] == 5
    end

    test "extracts JSON with thinking tags" do
      content = """
      <thinking>Let me evaluate this memory...</thinking>
      {"quality_score": 3, "recommendation": "human_review"}
      """

      assert {:ok, decoded} = LLM.extract_json_content(content)
      assert decoded["quality_score"] == 3
    end

    test "handles content with text before JSON using balanced extraction" do
      content = ~S(Some text before {"quality_score": 4, "recommendation": "approve"})
      assert {:ok, decoded} = LLM.extract_json_content(content)
      assert decoded["recommendation"] == "approve"
    end

    test "returns error for content with no JSON" do
      content = "This is just plain text with no JSON structure at all."
      assert LLM.extract_json_content(content) == :error
    end
  end

  describe "usage_tokens/1" do
    test "reads llm_utils normalized usage keys" do
      assert {10, 4, 14} =
               LLM.usage_tokens(%{usage: %{tokens_in: 10, tokens_out: 4, total_tokens: 14}})
    end

    test "falls back to prompt/completion aliases" do
      assert {3, 2, 5} =
               LLM.usage_tokens(%{"usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2}})
    end
  end

  describe "success telemetry reaches Axiom" do
    test "successful provider calls log at info level with llm_call action" do
      # Regression: success events were Logger.debug, which prod (:info) filters
      # out, so the steward-acs-llm dashboard never saw any usage — only failures.
      source = File.read!(Path.join([__DIR__, "../../lib/acs/llm.ex"]))

      assert String.contains?(source, ~S|Logger.info("[Acs.LLM] Provider #{provider_id} ok"|)
      assert String.contains?(source, ~s[action: "llm_call"])
      assert String.contains?(source, ~s[status: "ok"])
    end
  end

  describe "call_type is the calling process" do
    test "auditors and intake pass process names, not subject ids" do
      # Regression: call_type must be memory_audit / skill_audit / … — never the
      # memory/skill/spec id being processed (that goes in subject_id).
      source = File.read!(Path.join([__DIR__, "../../lib/acs/llm.ex"]))

      assert source =~ ~s[try_providers("memory_audit"]
      assert source =~ ~s[try_providers("skill_audit"]
      assert source =~ ~s[try_providers("spec_audit"]
      assert source =~ ~s[try_providers("intake"]
      assert source =~ ~s[try_providers("skill_intake"]
      assert source =~ "subject_id: subject_id"
      refute source =~ "try_providers(memory_id,"
      refute source =~ "try_providers(skill_name,"
      refute source =~ "try_providers(spec_id,"
    end
  end
end

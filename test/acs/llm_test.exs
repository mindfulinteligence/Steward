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

  describe "provider routing via Acs.LLM.Router" do
    test "enabled providers are resolved per call_type through the router" do
      source = File.read!(Path.join([__DIR__, "../../lib/acs/llm.ex"]))

      assert source =~ "get_enabled_providers(\"intake\")"
      assert source =~ "get_enabled_providers(\"skill_intake\")"
      assert source =~ "get_enabled_providers(\"memory_audit\")"
      assert source =~ "get_enabled_providers(\"skill_audit\")"
      assert source =~ "get_enabled_providers(\"spec_audit\")"
      assert source =~ "Acs.LLM.Router.priority_for(Acs.LLM.Router.region(), call_type)"
      assert source =~ "Acs.LLM.Router.model_for("
    end

    test "defines an app-side OpenRouter provider resolved via config_for/1" do
      source = File.read!(Path.join([__DIR__, "../../lib/acs/llm.ex"]))

      assert source =~ "config = config_for(provider_id)"
      assert source =~ "LLMUtils.Client.chat_completion(messages, config, opts)"
      assert source =~ ~s|"openrouter" => %{|
      assert source =~ "base_url: \"https://openrouter.ai/api/v1\""
      assert source =~ "default_model: \"deepseek/deepseek-4-flash\""
      assert source =~ "OPENROUTER_API_KEY"

      assert source =~
               "Map.get(@app_provider_configs, provider_id) || LLMUtils.Providers.get(provider_id)"
    end

    test "get_enabled_providers includes openrouter when routed and keyed" do
      old_priority = System.get_env("LLM_PRIORITY_INTAKE")
      old_key = Application.get_env(:steward_acs, :openrouter_api_key)
      old_whitelist = Application.get_env(:steward_acs, :enabled_llm_providers)

      on_exit(fn ->
        restore_env("LLM_PRIORITY_INTAKE", old_priority)
        if old_key, do: Application.put_env(:steward_acs, :openrouter_api_key, old_key)
        Application.put_env(:steward_acs, :enabled_llm_providers, old_whitelist)
      end)

      System.put_env("LLM_PRIORITY_INTAKE", "openrouter")
      Application.put_env(:steward_acs, :openrouter_api_key, "test-key")
      Application.put_env(:steward_acs, :enabled_llm_providers, [])

      providers = Acs.LLM.get_enabled_providers_for_test("intake")
      assert "openrouter" in providers
    end
  end

  defp restore_env(var, nil), do: System.delete_env(var)
  defp restore_env(var, val), do: System.put_env(var, val)

  describe "provider fallback telemetry" do
    test "emits a per-fallback info event with llm_fallback action" do
      # Regression: a provider failure followed by a success on the next provider
      # was only visible as the failed provider's warning — no signal that the
      # request itself succeeded. The fallback event lets Axiom count recoveries.
      source = File.read!(Path.join([__DIR__, "../../lib/acs/llm.ex"]))

      assert String.contains?(
               source,
               ~S|Logger.info("[Acs.LLM] Provider #{provider_id} failed, falling back to #{hd(rest)}"|
             )

      assert String.contains?(source, ~s[action: "llm_fallback"])
      assert String.contains?(source, "next_provider: hd(rest)")
    end

    test "emits a single all_providers_failed warning when every provider errors" do
      # Regression: with N providers the old code logged N error events, which
      # inflated the error rate; the aggregate is the true failure signal.
      source = File.read!(Path.join([__DIR__, "../../lib/acs/llm.ex"]))

      assert String.contains?(source, ~s[error_type: "all_providers_failed"])
      assert String.contains?(source, ~s[action: "llm_call"])
      assert String.contains?(source, "providers: providers")
      assert String.contains?(source, "count: length(providers)")
    end
  end
end

defmodule Acs.LLM.RouterTest do
  use ExUnit.Case, async: false

  alias Acs.LLM.Router

  @env_prefixes ["LLM_PRIORITY", "LLM_MODEL"]

  setup do
    saved =
      Enum.reduce(@env_prefixes, %{}, fn prefix, acc ->
        Enum.reduce(["SG_INTAKE", "SG", "INTAKE"], acc, fn suffix, inner ->
          var = "#{prefix}_#{suffix}"
          Map.put(inner, var, System.get_env(var))
        end)
      end)

    on_exit(fn ->
      Enum.each(saved, fn {var, value} ->
        if is_nil(value), do: System.delete_env(var), else: System.put_env(var, value)
      end)
    end)

    :ok
  end

  describe "priority_for/2 default" do
    test "returns the default list when nothing is configured" do
      assert Router.priority_for("default", "intake") == [
               "tokenrouter",
               "nim",
               "minimax",
               "openai"
             ]
    end
  end

  describe "priority_for/2 code fallback map" do
    test "region map can narrow providers for a region" do
      assert Router.priority_for("sg", "memory_audit") == ["tokenrouter", "openai"]
      assert Router.priority_for("us", "memory_audit") == ["openai"]
    end

    test "call-type override within a region beats the region default" do
      assert Router.priority_for("sg", "intake") == ["openai"]
    end

    test "unknown region falls back to default" do
      assert Router.priority_for("xx", "intake") == ["tokenrouter", "nim", "minimax", "openai"]
    end
  end

  describe "priority_for/2 env overrides" do
    test "call-type env override beats region code map" do
      System.put_env("LLM_PRIORITY_INTAKE", "openai")
      assert Router.priority_for("sg", "intake") == ["openai"]
      assert Router.priority_for("default", "intake") == ["openai"]

      assert Router.priority_for("default", "memory_audit") == [
               "tokenrouter",
               "nim",
               "minimax",
               "openai"
             ]
    end

    test "region env override beats code map" do
      System.put_env("LLM_PRIORITY_SG", "minimax")
      assert Router.priority_for("sg", "memory_audit") == ["minimax"]
    end

    test "region+call-type env override is the highest precedence" do
      System.put_env("LLM_PRIORITY_SG_INTAKE", "nim")
      System.put_env("LLM_PRIORITY_INTAKE", "openai")
      System.put_env("LLM_PRIORITY_SG", "minimax")
      assert Router.priority_for("sg", "intake") == ["nim"]
    end
  end

  describe "model_for/4" do
    test "returns base model when no env overrides" do
      assert Router.model_for("default", "openai", "intake", "gpt-4o") == "gpt-4o"
    end

    test "call-type env override beats base model" do
      System.put_env("LLM_MODEL_INTAKE", "deepseek/deepseek-4-flash")

      assert Router.model_for("default", "openai", "intake", "gpt-4o") ==
               "deepseek/deepseek-4-flash"

      assert Router.model_for("default", "openai", "memory_audit", "gpt-4o") == "gpt-4o"
    end

    test "region+call-type env override beats call-type-only" do
      System.put_env("LLM_MODEL_SG_INTAKE", "fast-region")
      System.put_env("LLM_MODEL_INTAKE", "fast-global")
      assert Router.model_for("sg", "openai", "intake", "gpt-4o") == "fast-region"
    end

    test "call_type is normalized case-insensitively" do
      System.put_env("LLM_MODEL_INTAKE", "fast")
      assert Router.model_for("default", "openai", "INTAKE", "base") == "fast"
    end
  end
end

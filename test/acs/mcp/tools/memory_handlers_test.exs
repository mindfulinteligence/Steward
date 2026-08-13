defmodule Acs.MCP.Tools.MemoryHandlersTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.Tools.MemoryHandlers
  alias Acs.Memory.SubjectIdentity

  describe "generate_guidance_packet/1" do
    test "rejects invalid mode values" do
      assert {:error, msg} =
               MemoryHandlers.generate_guidance_packet(%{
                 "scope_path" => "test/module",
                 "mode" => "invalid"
               })

      assert msg =~ "Invalid mode"
    end
  end

  describe "SubjectIdentity.distinct_subject?/2" do
    test "returns true when both sides name different subjects" do
      new = ["about-type:person", "about-name:Pang Yee Ean", "scope:gmc/bhutan"]
      existing = ["about-type:person", "about-name:Lee Seow Hiang"]

      assert SubjectIdentity.distinct_subject?(new, existing)
    end

    test "returns false when both sides name the same subject" do
      new = ["about-name:Pang Yee Ean", "about-type:person"]
      existing = ["about-name:Pang Yee Ean", "about-type:person"]

      refute SubjectIdentity.distinct_subject?(new, existing)
    end

    test "returns false when a side lacks a subject (fallback to similarity)" do
      refute SubjectIdentity.distinct_subject?(["about-name:Pang Yee Ean"], ["just-a-tag"])
    end

    test "reads about tags from a schema row's tags_json" do
      new = ["about-name:Pang Yee Ean", "about-type:person"]
      row = %{tags_json: Jason.encode!(["about-name:Pang Yee Ean", "about-type:person"])}

      refute SubjectIdentity.distinct_subject?(new, row)

      other_row = %{tags_json: Jason.encode!(["about-name:Lee Seow Hiang"])}
      assert SubjectIdentity.distinct_subject?(new, other_row)
    end

    test "treats malformed tags_json as having no subject" do
      new = ["about-name:Pang Yee Ean"]
      row = %{tags_json: "not-json"}

      refute SubjectIdentity.distinct_subject?(new, row)
    end
  end
end

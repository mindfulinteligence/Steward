defmodule Acs.MCP.Tools.SkillHandlersTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.SkillHandlers

  setup do
    original_path = Application.get_env(:steward_acs, :obsidian_vault_path)
    vault = Path.join(System.tmp_dir!(), "acs_skill_save_#{System.unique_integer([:positive])}")
    Application.put_env(:steward_acs, :obsidian_vault_path, vault)
    File.mkdir_p!(Acs.Skills.Store.skill_dir())

    on_exit(fn ->
      if original_path do
        Application.put_env(:steward_acs, :obsidian_vault_path, original_path)
      else
        Application.delete_env(:steward_acs, :obsidian_vault_path)
      end

      File.rm_rf!(vault)
    end)

    :ok
  end

  test "skill_save allows a decent procedure in one pass" do
    assert {:ok, %{saved: true, status: "saved", name: "deploy-hotfix"}} =
             SkillHandlers.skill_save(%{
               "name" => "deploy-hotfix",
               "description" => "Ship an urgent hotfix",
               "content" => """
               ## Steps
               1. Branch from main
               2. Open PR with test plan
               3. Merge and watch Actions cutover
               4. Smoke the health endpoint
               """
             })
  end

  test "skill_save returns needs_input for one-liner (single-pass gate)" do
    assert {:ok, %{saved: false, status: "needs_input", questions: questions}} =
             SkillHandlers.skill_save(%{
               "name" => "not-a-skill",
               "content" => "Always lock files."
             })

    assert Enum.any?(questions, &(&1["id"] == "needs_improvement"))
  end

  test "intake_confirmed bypasses quality gate" do
    assert {:ok, %{saved: true}} =
             SkillHandlers.skill_save(%{
               "name" => "tiny-ok",
               "content" => "Always lock files.",
               "intake_confirmed" => true
             })
  end

  test "skill_save pre-fills scope_paths from the caller's current task scope" do
    agent_id = "d3_prefill_agent_#{System.unique_integer([:positive])}"

    {:ok, task} =
      Acs.create_task(
        %{
          "title" => "D3 scope prefill test",
          "file_paths" => ["lib/acs/mcp/tools/skill_handlers.ex"]
        },
        agent_id
      )

    Acs.Acs.put_agent_status(agent_id, %{current_task_id: task.id, purpose: "active"})

    assert {:ok, %{saved: true}} =
             SkillHandlers.skill_save(%{
               "name" => "d3-prefill",
               "content" => "## Steps\n1. Do the thing\n2. Verify\n",
               "intake_confirmed" => true,
               "_auth_agent_id" => agent_id
             })

    assert %{scope_paths: ["lib/acs/mcp/tools"]} =
             Acs.Skills.Store.get_skill("d3-prefill")
  end

  test "skill_save without a current task leaves scope_paths empty" do
    assert {:ok, %{saved: true}} =
             SkillHandlers.skill_save(%{
               "name" => "d3-noscope",
               "content" => "## Steps\n1. Do the thing\n2. Verify\n",
               "intake_confirmed" => true
             })

    assert %{scope_paths: []} = Acs.Skills.Store.get_skill("d3-noscope")
  end

  describe "skill_get content gating" do
    test "name lookup returns name + content only" do
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "gated-proc",
                 "description" => "A gated procedure",
                 "when_to_use" => "When testing content gating",
                 "content" => """
                 ## Steps
                 1. Do the thing
                 2. Verify it worked
                 3. Recover if it failed
                 """,
                 "intake_confirmed" => true
               })

      assert {:ok, %{skills: [body], total: 1}} =
               SkillHandlers.skill_get(%{"name" => "gated-proc"})

      assert body == %{
               name: "gated-proc",
               content:
                 String.trim("""
                 ## Steps
                 1. Do the thing
                 2. Verify it worked
                 3. Recover if it failed
                 """)
             }

      refute Map.has_key?(body, :status)
      refute Map.has_key?(body, :id)
      refute Map.has_key?(body, :description)
    end

    test "search returns discovery cards without content, status, or id" do
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "searchable-proc",
                 "description" => "Findable by search",
                 "content" => "## Steps\n1. UniqueSearchTokenXYZ\n2. Verify\n",
                 "intake_confirmed" => true
               })

      assert {:ok, %{skills: skills}} =
               SkillHandlers.skill_get(%{"search" => "searchable-proc"})

      card = Enum.find(skills, &(&1.name == "searchable-proc"))
      assert card.description == "Findable by search"
      refute Map.has_key?(card, :content)
      refute Map.has_key?(card, :status)
      refute Map.has_key?(card, :id)
    end
  end

  describe "rank-gated edits (unified role management)" do
    test "member cannot edit an existing skill at or above own rank" do
      # Stamped as rank 1 by an admin (admin can edit anything).
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "ranked-proc",
                 "content" => "## Steps\n1. Do the thing\n2. Verify\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "admin",
                 "_auth_authority_sort_order" => 1
               })

      # Member at a lower rank (2) tries to edit rank-1 content -> denied.
      assert {:error, msg} =
               SkillHandlers.skill_save(%{
                 "name" => "ranked-proc",
                 "content" => "## Steps\n1. Changed\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "member",
                 "_auth_authority_sort_order" => 2
               })

      assert msg =~ "Access denied"
    end

    test "top-rank member can edit a skill at their own level" do
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "own-rank-proc",
                 "content" => "## Steps\n1. Do the thing\n2. Verify\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "admin",
                 "_auth_authority_sort_order" => 1
               })

      # Member at the top rank (1) can edit rank-1 content (own level).
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "own-rank-proc",
                 "content" => "## Steps\n1. Changed\n2. Verify\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "member",
                 "_auth_authority_sort_order" => 1
               })
    end

    test "member can edit a skill strictly below own rank" do
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "low-rank-proc",
                 "content" => "## Steps\n1. Do it\n2. Check\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "admin",
                 "_auth_authority_sort_order" => 5
               })

      # Member at rank 2 can edit rank-5 content (strictly below).
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "low-rank-proc",
                 "content" => "## Steps\n1. Done\n2. Verify\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "member",
                 "_auth_authority_sort_order" => 2
               })
    end

    test "unranked skill is editable by a ranked member" do
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "unranked-proc",
                 "content" => "## Steps\n1. Do\n2. Verify\n",
                 "intake_confirmed" => true
               })

      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "unranked-proc",
                 "content" => "## Steps\n1. Updated\n2. Verify\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "member",
                 "_auth_authority_sort_order" => 2
               })
    end
  end
end

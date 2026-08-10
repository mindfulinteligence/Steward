defmodule Acs.MCP.Tools.ChatSurface do
  @moduledoc """
  Consolidated MCP façade for chat clients.

  Coding clients continue to use the fine-grained tools directly. This module
  only routes the three chat-facing discriminated unions to the existing
  handlers, preserving the injected authentication context.
  """

  alias Acs.MCP.Tools.CoreHandlers
  alias Acs.MCP.Tools.ErrorHandlers
  alias Acs.MCP.Tools.MemoryHandlers
  alias Acs.MCP.Tools.PersonHandlers
  alias Acs.MCP.Tools.QueryAgent
  alias Acs.MCP.Tools.SkillHandlers

  @legacy_routes %{
    "get_started" => {"steward_ask", "action", "start"},
    "ask" => {"steward_ask", "action", "search"},
    "skill_get" => {"steward_ask", "action", "skill"},
    "specs_get" => {"steward_ask", "action", "document"},
    "get_person_status" => {"steward_ask", "action", "person_status"},
    "get_present_status" => {"steward_ask", "action", "present_status"},
    "list_tasks" => {"steward_ask", "action", "list_tasks"},
    "save_memory" => {"steward_write", "kind", "memory"},
    "set_memory_status" => {"steward_write", "kind", "memory_status"},
    "documents_propose" => {"steward_write", "kind", "document"},
    "skill_save" => {"steward_write", "kind", "skill"},
    "set_person_status" => {"steward_write", "kind", "person_status"},
    "submit_task_feedback" => {"steward_write", "kind", "feedback"},
    "create_work" => {"steward_work", "action", "create"},
    "claim_work" => {"steward_work", "action", "claim"},
    "release_work" => {"steward_work", "action", "release"},
    "close_work" => {"steward_work", "action", "close"},
    "resolve_user_task" => {"steward_work", "action", "resolve_reminder"}
  }

  @doc "The three tool definitions advertised to chat clients."
  def tool_defs do
    [steward_ask_def(), steward_write_def(), steward_work_def()]
  end

  @doc "Routes one of the consolidated chat tools to an existing handler."
  def call("steward_ask", args), do: steward_ask(args)
  def call("steward_write", args), do: steward_write(args)
  def call("steward_work", args), do: steward_work(args)

  def steward_ask(args), do: ask(args)
  def steward_write(args), do: write(args)
  def steward_work(args), do: work(args)

  @doc "Returns the fine-grained tool represented by a consolidated call."
  def routed_tool("steward_ask", args), do: ask_route(args)
  def routed_tool("steward_write", args), do: write_route(args)
  def routed_tool("steward_work", args), do: work_route(args)
  def routed_tool(_, _), do: nil

  @doc "Returns handler-compatible arguments for next-step generation."
  def canonical_args("steward_ask", args), do: drop_discriminator(args, "action")

  def canonical_args("steward_write", %{"kind" => "memory"} = args) do
    args
    |> drop_discriminator("kind")
    |> maybe_rename("memory_kind", "kind")
  end

  def canonical_args("steward_write", args), do: drop_discriminator(args, "kind")
  def canonical_args("steward_work", args), do: drop_discriminator(args, "action")
  def canonical_args(_, args), do: args

  @doc "Soft-cutover mapping for legacy names received from chat clients."
  def normalize_legacy_call(name, args, audience) when audience in [:chat, "chat"] do
    case Map.get(@legacy_routes, name) do
      {new_name, discriminator, value} ->
        args =
          if name == "save_memory" do
            args
            |> maybe_rename("kind", "memory_kind")
            |> Map.put(discriminator, value)
          else
            Map.put(args, discriminator, value)
          end

        {new_name, args}

      nil ->
        {name, args}
    end
  end

  def normalize_legacy_call(name, args, _audience), do: {name, args}

  @doc "Wrap a fine-grained `_next` step for the consolidated chat surface."
  def consolidate_step(%{tool: tool, params: params} = step) do
    case Map.get(@legacy_routes, tool) do
      {new_name, discriminator, value} ->
        params =
          if tool == "save_memory" do
            params
            |> maybe_rename_atom(:kind, :memory_kind)
            |> Map.put(String.to_atom(discriminator), value)
          else
            Map.put(params, String.to_atom(discriminator), value)
          end

        %{step | tool: new_name, params: params}

      nil ->
        step
    end
  end

  def consolidate_step(step), do: step

  defp ask(args) do
    case ask_route(args) do
      "get_started" ->
        CoreHandlers.acs_get_started(Map.put(args, "audience", "chat"))

      "ask" ->
        QueryAgent.ask(drop_discriminator(args, "action"))

      "skill_get" ->
        SkillHandlers.skill_get(drop_discriminator(args, "action"))

      "specs_get" ->
        Acs.Specs.Tools.call_tool("specs_get", drop_discriminator(args, "action"))

      "get_person_status" ->
        PersonHandlers.get_person_status(drop_discriminator(args, "action"))

      "get_present_status" ->
        CoreHandlers.acs_get_present_status(drop_discriminator(args, "action"))

      "list_tasks" ->
        CoreHandlers.acs_list_tasks(drop_discriminator(args, "action"))

      nil ->
        {:error, "Invalid steward_ask action"}
    end
  end

  defp write(args) do
    routed_args = drop_discriminator(args, "kind")

    case write_route(args) do
      "save_memory" ->
        routed_args
        |> maybe_rename("memory_kind", "kind")
        |> MemoryHandlers.save_memory()

      "documents_propose" ->
        Acs.Specs.Tools.call_tool("documents_propose", routed_args)

      "skill_save" ->
        SkillHandlers.skill_save(routed_args)

      "set_memory_status" ->
        MemoryHandlers.set_memory_status(routed_args)

      "set_person_status" ->
        PersonHandlers.set_person_status(routed_args)

      "submit_task_feedback" ->
        ErrorHandlers.acs_submit_task_feedback(routed_args)

      nil ->
        {:error, "Invalid steward_write kind"}
    end
  end

  defp work(args) do
    routed_args = drop_discriminator(args, "action")

    case work_route(args) do
      "create_work" -> CoreHandlers.acs_create_work(routed_args)
      "claim_work" -> CoreHandlers.acs_claim_work(routed_args)
      "release_work" -> CoreHandlers.acs_release_work(routed_args)
      "close_work" -> CoreHandlers.acs_close_work(routed_args)
      "resolve_user_task" -> CoreHandlers.acs_resolve_user_task(routed_args)
      nil -> {:error, "Invalid steward_work action"}
    end
  end

  defp ask_route(args) do
    case Map.get(args, "action") do
      nil -> if user_args_empty?(args), do: "get_started", else: "ask"
      "start" -> "get_started"
      "search" -> "ask"
      "skill" -> "skill_get"
      "document" -> "specs_get"
      "person_status" -> "get_person_status"
      "present_status" -> "get_present_status"
      "list_tasks" -> "list_tasks"
      _ -> nil
    end
  end

  defp write_route(args) do
    case Map.get(args, "kind") do
      "memory" -> "save_memory"
      "document" -> "documents_propose"
      "skill" -> "skill_save"
      "memory_status" -> "set_memory_status"
      "person_status" -> "set_person_status"
      "feedback" -> "submit_task_feedback"
      _ -> nil
    end
  end

  defp work_route(args) do
    case Map.get(args, "action") do
      "create" -> "create_work"
      "claim" -> "claim_work"
      "release" -> "release_work"
      "close" -> "close_work"
      "resolve_reminder" -> "resolve_user_task"
      _ -> nil
    end
  end

  defp user_args_empty?(args) do
    args
    |> Map.keys()
    |> Enum.all?(fn key ->
      key in ["agent_id", "audience"] or
        (is_binary(key) and String.starts_with?(key, "_auth_"))
    end)
  end

  defp drop_discriminator(args, key), do: Map.delete(args, key)

  defp maybe_rename(args, from, to) do
    case Map.pop(args, from) do
      {nil, args} -> args
      {value, args} -> Map.put(args, to, value)
    end
  end

  defp maybe_rename_atom(args, from, to) do
    case Map.pop(args, from) do
      {nil, args} -> args
      {value, args} -> Map.put(args, to, value)
    end
  end

  def steward_ask_def do
    tool_def(
      "steward_ask",
      "Bootstrap and retrieve from Steward. Empty call or action=start returns the startup packet. Use action=search for org knowledge (skills/docs return excerpts — fetch bodies with action=skill name: or action=document app+path). Fetches return content only, not tags/status/audit. Follow process docs/skills before acting.",
      [
        branch(%{}, []),
        branch(%{"action" => enum("start")}, ["action"]),
        default_search_branch(),
        branch(search_properties(), ["action"]),
        branch(skill_get_properties(), ["action"]),
        branch(document_get_properties(), ["action", "app", "path"]),
        branch(person_get_properties(), ["action"]),
        branch(present_status_properties(), ["action"]),
        branch(list_tasks_properties(), ["action"])
      ]
    )
  end

  def steward_write_def do
    tool_def(
      "steward_write",
      "Persist knowledge, update status, or send feedback. Choose exactly one kind. For kind=memory, memory_kind is the existing memory classification (decision, invariant, warning, etc.). Memories, documents, and skills are stored in the database (or local files in single-tenant mode); no manual directory setup is needed.",
      [
        branch(memory_properties(), ["kind", "memory_kind", "title", "content", "scope_path"]),
        branch(document_properties(), ["kind", "app", "path"]),
        branch(skill_save_properties(), ["kind", "name", "content"]),
        branch(memory_status_properties(), ["kind", "memory_id", "status"]),
        branch(person_set_properties(), ["kind", "status"]),
        branch(feedback_properties(), ["kind"])
      ]
    )
  end

  def steward_work_def do
    tool_def(
      "steward_work",
      "Create reminders or coordinate tracked work. Choose action=create, claim, release, close, or resolve_reminder. Timed reminders use create with kind=user plus due_at and remind_at.",
      [
        branch(create_work_properties(), ["action", "title"]),
        branch(claim_work_properties(), ["action", "task_id"]),
        branch(release_work_properties(), ["action", "task_id"]),
        branch(close_work_properties(), ["action", "task_id"]),
        branch(resolve_reminder_properties(), ["action", "task_id", "outcome"])
      ]
    )
  end

  defp tool_def(name, description, branches) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{"type" => "object", "oneOf" => branches}
    }
  end

  defp branch(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp default_search_branch do
    search_properties()
    |> Map.delete("action")
    |> branch([])
    |> Map.put("minProperties", 1)
  end

  defp enum(value), do: %{"type" => "string", "enum" => [value]}
  defp string(description), do: %{"type" => "string", "description" => description}
  defp boolean(description), do: %{"type" => "boolean", "description" => description}
  defp integer(description), do: %{"type" => "integer", "description" => description}

  defp strings(description),
    do: %{"type" => "array", "items" => %{"type" => "string"}, "description" => description}

  defp search_properties do
    %{
      "action" => enum("search"),
      "content_query" => string("Search memories, documents, skills, and status"),
      "kind" => string("Memory kind filter"),
      "team" => string("Team filter"),
      "project" => string("Project filter"),
      "document_type" => string("Document type filter"),
      "limit" => integer("Maximum results per category"),
      "include_documents" => boolean("Include documents"),
      "include_skills" => boolean("Include skills"),
      "include_agent_status" => boolean("Include agent presence"),
      "status" => string("Memory status filter")
    }
  end

  defp skill_get_properties do
    %{
      "action" => enum("skill"),
      "name" => string("Exact skill name — returns procedure body"),
      "search" => string("Skill keyword search"),
      "tag" => string("Skill tag filter"),
      "scope_path" => string("Business or code scope"),
      "mode" => %{"type" => "string", "enum" => ["hybrid", "keyword", "semantic"]}
    }
  end

  defp document_get_properties do
    %{
      "action" => enum("document"),
      "app" => string("App from search hit (e.g. steward_acs)"),
      "path" => string("Document path — returns body content only")
    }
  end

  defp person_get_properties do
    %{
      "action" => enum("person_status"),
      "email" => string("Person email"),
      "name" => string("Person display name")
    }
  end

  defp present_status_properties do
    %{"action" => enum("present_status"), "status_filter" => string("Optional presence filter")}
  end

  defp list_tasks_properties do
    %{
      "action" => enum("list_tasks"),
      "status_filter" => string("Task status filter"),
      "kind" => %{"type" => "string", "enum" => ["user", "coordination"]},
      "for_user" => string("Person whose reminders to list")
    }
  end

  defp memory_properties do
    %{
      "kind" => enum("memory"),
      "memory_kind" =>
        string(
          "Memory classification: learning, warning, pattern, bug, decision, invariant, or axiom"
        ),
      "title" => string("Specific, self-contained memory title"),
      "content" => string("Durable truth with rationale"),
      "scope_path" => string("Business or code scope"),
      "tags" => strings("Categorization tags"),
      "triggers" => strings("Trigger events"),
      "importance" => integer("Importance from 1 to 5"),
      "summary" => string("Brief summary"),
      "failure_modes" => strings("Potential failure modes"),
      "visibility" => %{"type" => "string", "enum" => ["org", "team", "project", "personal"]},
      "team" => string("Required when visibility=team"),
      "project" => string("Required when visibility=project"),
      "confidential" => boolean("Shortcut for personal visibility"),
      "about_type" => %{"type" => "string", "enum" => ["person", "company"]},
      "about_name" => string("Display name of the subject"),
      "about_email" => string("Email of a person subject"),
      "intake_confirmed" => boolean("Retry after answering intake questions")
    }
  end

  defp document_properties do
    %{
      "kind" => enum("document"),
      "app" => string("App or project name"),
      "path" => string("Document path, preferably documents/<type>/<slug>"),
      "title" => string("Human-readable title"),
      "document_type" => %{
        "type" => "string",
        "enum" => [
          "knowledge",
          "project",
          "marketing",
          "deliverable",
          "policy",
          "process",
          "guideline",
          "reference"
        ]
      },
      "content" => string("Full markdown document body"),
      "source" => string("Source file path, URL, or asset folder"),
      "project" => string("Project scope for filtering"),
      "tags" => strings("Search tags")
    }
  end

  defp skill_save_properties do
    %{
      "kind" => enum("skill"),
      "name" => string("Unique skill name"),
      "content" => string("Markdown procedure"),
      "tags" => strings("Categorization tags"),
      "description" => string("Short description"),
      "when_to_use" => string("When agents should load this skill"),
      "scope_paths" => strings("Applicable scopes"),
      "intake_confirmed" => boolean("Retry after answering intake questions")
    }
  end

  defp memory_status_properties do
    %{
      "kind" => enum("memory_status"),
      "memory_id" => string("Memory ID"),
      "status" => %{"type" => "string", "enum" => ["stale", "deprecated"]},
      "notes" => string("Reason for the status change")
    }
  end

  defp person_set_properties do
    %{
      "kind" => enum("person_status"),
      "email" => string("Person email"),
      "name" => string("Person display name"),
      "status" => string("Job status or title"),
      "rank" => string("Organization authority level slug or label")
    }
  end

  defp feedback_properties do
    %{
      "kind" => enum("feedback"),
      "task_id" => string("Tracked task slug; omit for standalone feedback"),
      "learned_for_agents" => string("Reusable insight"),
      "had_issues" => string("Problems encountered"),
      "improvements" => string("Suggested Steward improvements"),
      "tools_wish_list" => string("Desired tools or capabilities"),
      "info_needed" => string("Missing or hard-to-find information"),
      "guidance_useful" => boolean("Whether guidance was useful"),
      "guidance_items_helpful" => strings("Helpful memory IDs"),
      "guidance_items_confusing" => strings("Confusing memory IDs"),
      "guidance_missing" => string("Missing guidance")
    }
  end

  defp create_work_properties do
    %{
      "action" => enum("create"),
      "title" => string("Task or reminder title"),
      "claim" => boolean("Immediately claim coordination work"),
      "kind" => %{"type" => "string", "enum" => ["user", "coordination"]},
      "assignee" => string("Reminder assignee"),
      "due_at" => string("Reminder due time in ISO-8601"),
      "remind_at" => string("Reminder surfacing time in ISO-8601"),
      "description" => string("Work description"),
      "file_paths" => strings("Relevant files"),
      "application" => string("Application scope"),
      "component" => string("Component scope")
    }
  end

  defp claim_work_properties do
    %{
      "action" => enum("claim"),
      "task_id" => string("Coordination task slug"),
      "scope_path" => string("Guidance scope"),
      "application" => string("Application scope"),
      "component" => string("Component scope")
    }
  end

  defp release_work_properties do
    %{"action" => enum("release"), "task_id" => string("Coordination task slug")}
  end

  defp close_work_properties do
    %{
      "action" => enum("close"),
      "task_id" => string("Coordination task slug"),
      "app" => string("App or project name; omit to skip spec save"),
      "path" => string("Entry path; omit to skip spec save"),
      "title" => string("Spec/document title"),
      "document_type" => %{
        "type" => "string",
        "enum" => [
          "spec",
          "knowledge",
          "project",
          "marketing",
          "deliverable",
          "policy",
          "process",
          "guideline",
          "reference"
        ]
      },
      "purpose" => string("For module specs: why this module exists"),
      "content" => string("Full markdown body for documents"),
      "learned_for_agents" => string("Reusable insight"),
      "had_issues" => string("Problems encountered"),
      "improvements" => string("Suggested Steward improvements"),
      "guidance_useful" => boolean("Whether guidance was useful")
    }
  end

  defp resolve_reminder_properties do
    %{
      "action" => enum("resolve_reminder"),
      "task_id" => string("Reminder task slug"),
      "outcome" => %{"type" => "string", "enum" => ["done", "dismiss", "remind_later"]},
      "remind_at" => string("Required for remind_later")
    }
  end
end

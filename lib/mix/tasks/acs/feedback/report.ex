defmodule Mix.Tasks.Acs.Feedback.Report do
  @moduledoc """
  Generate feedback analysis report.

  Run with: mix acs:feedback:report
  """
  use Mix.Task

  def run(_args) do
    :ok = ensure_started()
    Mix.Shell.IO.info("=== Task Completion Feedback Report ===\n")

    feedback = query_feedback()

    if Enum.empty?(feedback) do
      Mix.Shell.IO.info("No feedback submissions yet.")
    else
      summarize_learned(feedback)
      Mix.Shell.IO.info("")
      summarize_issues(feedback)
      Mix.Shell.IO.info("")
      summarize_improvements(feedback)
      Mix.Shell.IO.info("")
      summarize_tools_wishlist(feedback)
      Mix.Shell.IO.info("")
      summarize_info_needed(feedback)
      Mix.Shell.IO.info("")
      summarize_top_requests(feedback)
      Mix.Shell.IO.info("")
      summarize_actionable_insights(feedback)
      Mix.Shell.IO.info("")
      summarize_guidance_effectiveness(feedback)
      Mix.Shell.IO.info("")
      summarize_guidance_helpful_items(feedback)
      Mix.Shell.IO.info("")
      summarize_guidance_confusing_items(feedback)
      Mix.Shell.IO.info("")
      summarize_guidance_missing(feedback)
      Mix.Shell.IO.info("")
      summarize_priority_actions(feedback)
    end
  end

  defp query_feedback do
    case Acs.Repo.all(Acs.Acs.TaskCompletionFeedback) do
      nil -> []
      results -> results
    end
  end

  defp summarize_learned(feedback) do
    Mix.Shell.IO.info("--- Learned for Future Agents ---")
    Mix.Shell.IO.info("  (what agents learned that will help future agents)")
    entries = feedback |> Enum.map(& &1.learned_for_agents) |> Enum.reject(&is_nil/1)

    if Enum.empty?(entries) do
      Mix.Shell.IO.info("  (none)")
    else
      entries
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(5)
      |> Enum.each(fn {text, count} ->
        Mix.Shell.IO.info("  [#{count}] #{text}")
      end)
    end
  end

  defp summarize_issues(feedback) do
    Mix.Shell.IO.info("--- Issues Encountered ---")
    Mix.Shell.IO.info("  (what obstacles agents encountered)")
    entries = feedback |> Enum.map(& &1.most_time_consuming) |> Enum.reject(&is_nil/1)

    if Enum.empty?(entries) do
      Mix.Shell.IO.info("  (none)")
    else
      entries
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(5)
      |> Enum.each(fn {text, count} ->
        Mix.Shell.IO.info("  [#{count}] #{text}")
      end)
    end
  end

  defp summarize_improvements(feedback) do
    Mix.Shell.IO.info("--- Improvements Needed ---")
    Mix.Shell.IO.info("  (what could have made tasks easier)")
    entries = feedback |> Enum.map(& &1.improvements_needed) |> Enum.reject(&is_nil/1)

    if Enum.empty?(entries) do
      Mix.Shell.IO.info("  (none)")
    else
      entries
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(5)
      |> Enum.each(fn {text, count} ->
        Mix.Shell.IO.info("  [#{count}] #{text}")
      end)
    end
  end

  defp summarize_tools_wishlist(feedback) do
    Mix.Shell.IO.info("--- Tools Wish List ---")
    entries = feedback |> Enum.map(& &1.tools_wish_list) |> Enum.reject(&is_nil/1)

    if Enum.empty?(entries) do
      Mix.Shell.IO.info("  (none)")
    else
      entries
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(5)
      |> Enum.each(fn {text, count} ->
        Mix.Shell.IO.info("  [#{count}] #{text}")
      end)
    end
  end

  defp summarize_info_needed(feedback) do
    Mix.Shell.IO.info("--- Info Needed ---")
    entries = feedback |> Enum.map(& &1.info_needed) |> Enum.reject(&is_nil/1)

    if Enum.empty?(entries) do
      Mix.Shell.IO.info("  (none)")
    else
      entries
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(5)
      |> Enum.each(fn {text, count} ->
        Mix.Shell.IO.info("  [#{count}] #{text}")
      end)
    end
  end

  # === SYNTHESIS SECTION ===
  # Top tool/info requests across all feedback
  defp summarize_top_requests(feedback) do
    Mix.Shell.IO.info("=== TOP TOOL REQUESTS ===")

    entries =
      feedback
      |> Enum.flat_map(fn f ->
        [f.tools_wish_list, f.info_needed]
        |> Enum.map(&maybe_downcase/1)
        |> Enum.reject(&is_nil/1)
      end)

    if Enum.empty?(entries) do
      Mix.Shell.IO.info("  (none)")
    else
      entries
      |> categorize_tool_requests()
      |> Enum.sort_by(fn {_category, count} -> -count end)
      |> Enum.each(fn {category, count} ->
        Mix.Shell.IO.info("  [#{count}] #{category}")
      end)
    end
  end

  defp categorize_tool_requests(entries) do
    categorized = %{
      "Search/find tools needed" => 0,
      "Diagnostic tools" => 0,
      "Config tools" => 0,
      "Documentation" => 0,
      "Other" => 0
    }

    entries
    |> Enum.reduce(categorized, fn entry, acc ->
      category =
        cond do
          matches_category(entry, ["search", "find", "look up", "locate"]) ->
            "Search/find tools needed"

          matches_category(entry, ["diagnostic", "debug", "status", "check connection"]) ->
            "Diagnostic tools"

          matches_category(entry, ["config", "configuration", "setting"]) ->
            "Config tools"

          matches_category(entry, ["doc", "document", "readme", "guide", "architecture"]) ->
            "Documentation"

          true ->
            "Other"
        end

      Map.update!(acc, category, &(&1 + 1))
    end)
    |> Enum.reject(fn {_k, v} -> v == 0 end)
  end

  defp matches_category(entry, keywords) do
    entry_lower = String.downcase(entry)
    Enum.any?(keywords, fn kw -> String.contains?(entry_lower, kw) end)
  end

  # Actionable insights - group similar feedback with agent context
  defp summarize_actionable_insights(feedback) do
    Mix.Shell.IO.info("=== ACTIONABLE INSIGHTS ===")
    insights = build_actionable_insights(feedback)

    if Enum.empty?(insights) do
      Mix.Shell.IO.info("  (none)")
    else
      insights
      |> Enum.each(fn insight ->
        Mix.Shell.IO.info("  - #{insight}")
      end)
    end
  end

  defp build_actionable_insights(feedback) do
    tool_requests = feedback |> Enum.map(& &1.tools_wish_list) |> Enum.reject(&is_nil/1)
    info_requests = feedback |> Enum.map(& &1.info_needed) |> Enum.reject(&is_nil/1)

    insights = []

    # Group tool requests
    insights =
      if Enum.any?(tool_requests) do
        grouped = Enum.frequencies(tool_requests)

        Enum.reduce(grouped, insights, fn {request, count}, acc ->
          agents_for_request = get_agents_for_request(feedback, request)
          agent_str = format_agents(agents_for_request)

          cond do
            matches_category(request, ["search", "find", "look up", "locate"]) ->
              [
                "\"Find similar code tool\" requested by #{agent_str} → consider adding code search"
                | acc
              ]

            matches_category(request, ["debug", "diagnostic", "status", "check"]) ->
              [
                "\"Connection diagnostics\" requested by #{agent_str} → consider adding diagnostic tools"
                | acc
              ]

            matches_category(request, ["config", "setting"]) ->
              [
                "\"Better config management\" requested by #{agent_str} → enhance configuration tooling"
                | acc
              ]

            true ->
              if count > 1 do
                ["\"#{request}\" requested by multiple agents → prioritize development" | acc]
              else
                acc
              end
          end
        end)
      else
        insights
      end

    # Group info requests
    if Enum.any?(info_requests) do
      grouped = Enum.frequencies(info_requests)

      Enum.reduce(grouped, insights, fn {request, count}, acc ->
        agents_for_request = get_agents_for_request(feedback, request)

        cond do
          matches_category(request, ["doc", "document", "readme", "guide", "architecture"]) and
              count > 1 ->
            ["\"Project architecture docs\" requested by multiple agents → prioritize docs" | acc]

          matches_category(request, ["search", "find", "across files"]) ->
            [
              "\"Better search across files\" requested by #{format_agents(agents_for_request)} → enhance file search"
              | acc
            ]

          true ->
            acc
        end
      end)
    else
      insights
    end
  end

  defp get_agents_for_request(feedback, request) do
    feedback
    |> Enum.filter(fn f ->
      f.tools_wish_list == request or f.info_needed == request
    end)
    |> Enum.map(& &1.agent_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp format_agents([]), do: "multiple agents"
  defp format_agents([agent]), do: agent
  defp format_agents(agents), do: Enum.join(agents, ", ")

  # Priority actions - ranked recommendations
  defp summarize_priority_actions(feedback) do
    Mix.Shell.IO.info("=== PRIORITY ACTIONS ===")
    priorities = build_priority_actions(feedback)

    if Enum.empty?(priorities) do
      Mix.Shell.IO.info("  (none)")
    else
      priorities
      |> Enum.with_index(1)
      |> Enum.each(fn {{priority, action}, idx} ->
        Mix.Shell.IO.info("  #{idx}. (#{priority}) #{action}")
      end)
    end
  end

  defp build_priority_actions(feedback) do
    all_requests =
      feedback
      |> Enum.flat_map(fn f ->
        [maybe_downcase(f.tools_wish_list), maybe_downcase(f.info_needed)]
        |> Enum.reject(&is_nil/1)
      end)

    if Enum.empty?(all_requests) do
      []
    else
      priorities = []

      # Count occurrences of each request type
      search_count = count_matching(all_requests, ["search", "find", "look up", "locate"])

      doc_count =
        count_matching(all_requests, ["doc", "document", "readme", "guide", "architecture"])

      diag_count =
        count_matching(all_requests, ["diagnostic", "debug", "status", "check connection"])

      config_count = count_matching(all_requests, ["config", "configuration", "setting"])

      priorities =
        if search_count > 0,
          do: [{"HIGH", "Add code search/find tool"} | priorities],
          else: priorities

      priorities =
        if doc_count > 0,
          do: [{"HIGH", "Create project documentation"} | priorities],
          else: priorities

      priorities =
        if diag_count > 0,
          do: [{"MED", "Add connection diagnostics"} | priorities],
          else: priorities

      priorities =
        if config_count > 0,
          do: [{"MED", "Improve configuration management"} | priorities],
          else: priorities

      priorities
      |> Enum.sort_by(fn {priority, _} ->
        if priority == "HIGH", do: 0, else: 1
      end)
    end
  end

  defp count_matching(entries, keywords) do
    entries
    |> Enum.filter(fn entry -> matches_category(entry, keywords) end)
    |> length()
  end

  defp maybe_downcase(nil), do: nil
  defp maybe_downcase(str), do: String.downcase(str)

  # ── Guidance Effectiveness ──

  defp summarize_guidance_effectiveness(feedback) do
    total = length(feedback)
    useful = feedback |> Enum.filter(fn f -> f.guidance_useful == true end) |> length()
    not_useful = feedback |> Enum.filter(fn f -> f.guidance_useful == false end) |> length()
    unset = total - useful - not_useful
    useful_rate = percentage(useful, total)
    not_useful_rate = percentage(not_useful, total)

    Mix.Shell.IO.info("=== GUIDANCE EFFECTIVENESS ===")
    Mix.Shell.IO.info("  Agents found guidance USEFUL: #{useful}/#{total} (#{useful_rate})")

    Mix.Shell.IO.info(
      "  Agents found guidance NOT USEFUL: #{not_useful}/#{total} (#{not_useful_rate})"
    )

    Mix.Shell.IO.info("  Agents didn't rate guidance: #{unset} (#{percentage(unset, total)})")

    # Summary verdict
    Mix.Shell.IO.info("")

    if useful > not_useful && useful > 0 do
      Mix.Shell.IO.info("  [OK] GUIDANCE IS HELPING - More agents find it useful than not")
    else
      if not_useful > useful do
        Mix.Shell.IO.info("  [WARN] GUIDANCE NEEDS IMPROVEMENT - More agents find it not useful")
      else
        Mix.Shell.IO.info("  [INFO] MIXED RESULTS - Guidance effectiveness is balanced")
      end
    end
  end

  defp summarize_guidance_helpful_items(feedback) do
    Mix.Shell.IO.info("=== WHAT'S WORKING (Guidance Items That Helped) ===")
    Mix.Shell.IO.info("  Memory IDs that agents marked as helpful:")

    helpful_ids =
      feedback
      |> Enum.flat_map(fn f -> decode_guidance_items(f.guidance_items_helpful) end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(helpful_ids) do
      Mix.Shell.IO.info("  (none reported - add guidance_items_helpful when submitting feedback)")
    else
      helpful_ids
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(10)
      |> Enum.each(fn {id, count} ->
        Mix.Shell.IO.info("  [OK] #{id} (helped #{count} agent(s))")
      end)
    end
  end

  defp summarize_guidance_confusing_items(feedback) do
    Mix.Shell.IO.info("=== WHAT'S NOT WORKING (Guidance Items Confusing/Unhelpful) ===")
    Mix.Shell.IO.info("  Memory IDs that agents marked as confusing or not helpful:")

    confusing_ids =
      feedback
      |> Enum.flat_map(fn f -> decode_guidance_items(f.guidance_items_confusing) end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(confusing_ids) do
      Mix.Shell.IO.info("  (none reported - good sign!)")
    else
      confusing_ids
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(10)
      |> Enum.each(fn {id, count} ->
        Mix.Shell.IO.info("  [ERROR] #{id} (confusing for #{count} agent(s))")
      end)
    end
  end

  defp summarize_guidance_missing(feedback) do
    Mix.Shell.IO.info("=== GUIDANCE GAPS (What Agents Needed But Didn't Have) ===")
    entries = feedback |> Enum.map(& &1.guidance_missing) |> Enum.reject(&is_nil/1)

    if Enum.empty?(entries) do
      Mix.Shell.IO.info("  (no gaps reported)")
    else
      entries
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, v} -> -v end)
      |> Enum.take(5)
      |> Enum.each(fn {text, count} ->
        Mix.Shell.IO.info("  [WARN] \"#{text}\" (mentioned by #{count} agent(s))")
      end)
    end
  end

  # guidance_items_helpful / guidance_items_confusing are stored as JSON-array
  # strings (encode_array_field in error_handlers.ex). Decode to a list for
  # flat_mapping; anything unparseable degrades to [].
  defp decode_guidance_items(nil), do: []
  defp decode_guidance_items(items) when is_list(items), do: items

  defp decode_guidance_items(items) when is_binary(items) do
    case Jason.decode(items) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _ -> []
    end
  end

  defp decode_guidance_items(_), do: []

  defp percentage(count, total) do
    if total == 0 do
      "0%"
    else
      "#{round(count / total * 100)}%"
    end
  end

  defp ensure_started do
    # Ensure the application and all its dependencies are started
    # This starts Acs.Repo via the supervision tree
    case Application.ensure_all_started(:steward_acs) do
      {:ok, _} -> :ok
      # If it fails, let the task handle the error downstream
      {:error, _} -> :ok
    end
  rescue
    # If Application isn't available or other error, that's ok - the task will handle it
    _ -> :ok
  end
end

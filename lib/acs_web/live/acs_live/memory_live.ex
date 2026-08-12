defmodule AcsWeb.AcsLive.MemoryLive do
  @moduledoc """
  LiveView for human governance of the Steward Memory System.

  Provides:
  - Pending approvals list with approve/reject
  - Memory detail view with full content
  - Quarantined files dashboard
  - Conflict alerts for overlapping memories
  """

  use AcsWeb, :live_view
  require Logger
  alias Acs.Memory.Conflict
  alias Acs.Memory.Indexer
  alias Acs.Memory.Search

  def on_mount(_params, _session, socket) do
    # Don't use get_connect_info - it fails on push_navigate reconnections
    # Let handle_params set current_path from URL instead
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(AcsWeb.PubSub, "acs")

    socket =
      socket
      |> assign(
        memories: [],
        pending_count: 0,
        approved_count: 0,
        rejected_count: 0,
        quarantined_count: 0,
        review_count: 0,
        total_count: 0,
        stale_count: 0,
        deprecated_count: 0,
        selected_memory: nil,
        selected_memory_ids: MapSet.new(),
        status_filter: "proposed",
        kind_filter: nil,
        search_query: "",
        conflict_alerts: %{},
        loading: connected?(socket)
      )

    socket =
      if connected?(socket) do
        send(self(), :load_data)
        socket
      else
        load_data(socket)
      end

    if connected?(socket), do: send(self(), :check_conflicts)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, url, socket) do
    view = Map.get(params, "view", "pending")
    path = url |> URI.parse() |> Map.get(:path, "/")

    status_filter =
      case view do
        "pending" ->
          "proposed"

        "quarantined" ->
          "parse_error"

        status
        when status in ~w(all proposed approved stale rejected deprecated archived review) ->
          status

        _ ->
          "proposed"
      end

    socket =
      assign(socket, current_path: path, status_filter: status_filter, search_query: "")
      |> load_data()

    # Handle pending memory selection (after approve/reject/stale actions)
    socket =
      if pending_id = socket.assigns[:pending_memory_selection] do
        memory = Enum.find(socket.assigns.memories, fn m -> m.id == pending_id end)
        assign(socket, selected_memory: memory, pending_memory_selection: nil)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select-memory", %{"id" => id}, socket) do
    memory = Enum.find(socket.assigns.memories, fn m -> m.id == id end)
    {:noreply, assign(socket, selected_memory: memory)}
  end

  def handle_event("toggle-select", %{"id" => id}, socket) do
    selected = socket.assigns.selected_memory_ids

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, selected_memory_ids: selected)}
  end

  def handle_event("clear-selection", _params, socket) do
    {:noreply, assign(socket, selected_memory_ids: MapSet.new())}
  end

  def handle_event("select-memory-key", %{"id" => id}, socket) do
    handle_event("select-memory", %{"id" => id}, socket)
  end

  @impl true
  def handle_event("deselect-memory", _, socket) do
    {:noreply, assign(socket, selected_memory: nil)}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    update_memory_status(socket, id, "approved", %{
      info: "Memory '#{id}' approved ✓",
      action: "approve"
    })
  end

  @impl true
  def handle_event("reject", %{"id" => id}, socket) do
    update_memory_status(socket, id, "rejected", %{
      info: "Memory '#{id}' rejected ✗",
      action: "reject"
    })
  end

  @impl true
  def handle_event("mark-stale", %{"id" => id}, socket) do
    update_memory_status(socket, id, "stale", %{
      info: "Memory '#{id}' marked as stale ⟳",
      action: "mark stale"
    })
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket = assign(socket, search_query: query, selected_memory_ids: MapSet.new()) |> load_data()
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter-status", %{"status" => status}, socket) do
    view =
      case status do
        "parse_error" ->
          "quarantined"

        status
        when status in ~w(all proposed approved stale rejected deprecated archived review) ->
          status

        _ ->
          "proposed"
      end

    {:noreply,
     socket
     |> assign(selected_memory_ids: MapSet.new())
     |> push_patch(to: "/memories?view=#{view}")}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("approve-all-proposed", _, socket) do
    # Fetch all proposed memories (up to 500)
    org = socket.assigns.current_org

    proposed_memories =
      Indexer.list_memories([status: "proposed", limit: 500, org: org] ++ viewer_abac(socket))

    actor = web_actor(socket)

    results =
      Enum.map(proposed_memories, fn memory ->
        public_id = Indexer.public_id(memory.id, org)

        case Acs.Memory.Store.transition(public_id, "approved",
               org: org,
               actor: actor,
               source: "web",
               message: "Bulk approve memory #{public_id}"
             ) do
          {:ok, _result} -> {:ok, memory.id}
          {:error, reason} -> {:error, memory.id, reason}
        end
      end)

    approved = Enum.count(results, fn r -> match?({:ok, _}, r) end)
    failed = Enum.count(results, fn r -> match?({:error, _, _}, r) end)

    flash_msg =
      "Approved #{approved} memories" <> if failed > 0, do: " (#{failed} failed)", else: ""

    socket = socket |> put_flash(:info, flash_msg) |> load_data()
    {:noreply, socket}
  end

  def handle_event("approve-selected", _, socket) do
    proposed_ids =
      socket.assigns.memories
      |> Enum.filter(
        &(&1.status == "proposed" and MapSet.member?(socket.assigns.selected_memory_ids, &1.id))
      )
      |> Enum.map(& &1.id)

    results =
      Enum.map(proposed_ids, fn id ->
        Acs.Memory.Store.transition(id, "approved",
          org: socket.assigns.current_org,
          actor: web_actor(socket),
          source: "web",
          message: "Bulk approve selected memory #{id}"
        )
      end)

    approved = Enum.count(results, &match?({:ok, _}, &1))

    {:noreply,
     socket
     |> assign(selected_memory_ids: MapSet.new(), selected_memory: nil, status_filter: "all")
     |> put_flash(
       :info,
       "Approved #{approved} selected memor#{if approved == 1, do: "y", else: "ies"}"
     )
     |> push_patch(to: "/memories?view=all")}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info(:check_conflicts, socket) do
    {:noreply,
     assign(socket,
       conflict_alerts:
         compute_conflict_alerts(socket.assigns.memories, socket.assigns.status_filter)
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:memory_updated, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp update_memory_status(socket, id, new_status, flash_opts) do
    case Acs.Memory.Store.transition(id, new_status,
           org: socket.assigns.current_org,
           actor: web_actor(socket),
           source: "web",
           message: "#{flash_opts[:action]} memory #{id}"
         ) do
      {:ok, _result} ->
        # Switch to "all" view — handle_params will load data and select the memory
        socket =
          socket
          |> assign(status_filter: "all", search_query: "", pending_memory_selection: id)
          |> put_flash(:info, flash_opts[:info])

        {:noreply, push_patch(socket, to: "/memories?view=all")}

      {:error, reason} ->
        Logger.error("[MemoryLive] Failed to #{flash_opts[:action]}: #{inspect(reason)}")

        {:noreply,
         put_flash(socket, :error, "Could not #{flash_opts[:action]} this memory. Try again.")}
    end
  end

  defp web_actor(socket) do
    case socket.assigns[:current_user] do
      %{id: id} = user ->
        %{type: "user", id: to_string(id), display: Map.get(user, :email) || Map.get(user, :name)}

      _ ->
        %{type: "user", id: "unknown"}
    end
  end

  # Same clearance rule as MCP: the viewer's own authority level, role never bypasses.
  defp viewer_abac(socket) do
    case socket.assigns[:current_user] do
      %{authority_level_slug: slug} -> [authority_level_slug: slug]
      _ -> []
    end
  end

  defp load_data(socket) do
    query = socket.assigns.search_query
    status_filter = socket.assigns.status_filter
    viewer = viewer_abac(socket)

    org = socket.assigns.current_org
    counts = Indexer.count_by_status(org)
    pending_count = Map.get(counts, "proposed", 0)
    approved_count = Map.get(counts, "approved", 0)
    rejected_count = Map.get(counts, "rejected", 0)
    quarantined_count = Map.get(counts, "parse_error", 0)
    stale_count = Map.get(counts, "stale", 0)
    deprecated_count = Map.get(counts, "deprecated", 0)
    total_count = counts |> Map.values() |> Enum.sum()
    review_count = Indexer.count_memories_needing_review(org, viewer)

    memories_opts = [limit: 100, org: org] ++ viewer

    memories_opts =
      case status_filter do
        "all" ->
          # No status option means every indexed lifecycle state is included.
          memories_opts

        "review" ->
          # Special: fetch memories needing human review — handled separately below
          memories_opts

        _ ->
          Keyword.put(memories_opts, :status, status_filter)
      end

    memories =
      if status_filter == "review" do
        Indexer.list_memories_needing_review([limit: 100, org: org] ++ viewer)
      else
        if query && query != "" do
          Search.search(query, memories_opts)
        else
          Indexer.list_memories(memories_opts)
        end
      end

    conflict_alerts =
      if connected?(socket), do: %{}, else: compute_conflict_alerts(memories, status_filter)

    selected_memory =
      if socket.assigns.selected_memory do
        Enum.find(memories, fn m -> m.id == socket.assigns.selected_memory.id end)
      end

    assign(socket,
      memories: memories,
      selected_memory: selected_memory,
      pending_count: pending_count,
      approved_count: approved_count,
      rejected_count: rejected_count,
      quarantined_count: quarantined_count,
      review_count: review_count,
      total_count: total_count,
      stale_count: stale_count,
      deprecated_count: deprecated_count,
      loading: false,
      conflict_alerts: conflict_alerts
    )
  end

  defp compute_conflict_alerts(memories, status_filter) do
    # Conflict alerts only make sense for proposed (pending approval) memories
    if status_filter == nil || status_filter == "proposed" do
      proposed = Enum.filter(memories, fn m -> m.status == "proposed" end)

      if proposed != [] do
        all_approved =
          Acs.Memory.Search.list(
            scope_path: nil,
            status: "approved",
            org: Acs.Org.current()
          )

        Enum.reduce(proposed, %{}, fn memory, acc ->
          tags = parse_tags_json(memory.tags_json)

          if tags != [] do
            try do
              flags = Conflict.check_in_memory(memory, tags, all_approved)

              if flags != [] do
                Map.put(acc, memory.id, flags)
              else
                acc
              end
            rescue
              exception ->
                Logger.warning(
                  "Conflict check failed for memory #{memory.id}: #{inspect(exception)}"
                )

                acc
            end
          else
            acc
          end
        end)
      else
        %{}
      end
    else
      %{}
    end
  end

  defp selected_memory_count(memories, selected_ids) do
    Enum.count(memories, &MapSet.member?(selected_ids, &1.id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="memory-governance">
      <section class="account-intro page-intro animate-in" aria-labelledby="memories-title">
        <p class="account-kicker" style="font-size: 0.5rem; margin-bottom: 6px;"><span>Knowledge</span> / Memories</p>
        <h1 id="memories-title" class="page-title">Memories</h1>
        <p class="page-description">Agent memories store learnings, patterns, and eternal truths discovered during work.</p>
      </section>

      <!-- Search Bar -->
      <div class="page-search">
        <form phx-change="search">
          <input
            name="query"
            type="text"
            class="search-input"
            placeholder="Search memories..."
            aria-label="Search memories"
            value={@search_query}
          />
        </form>
      </div>

      <!-- Status cards -->
      <div class="stats-grid">
        <.stat_card label="Total" value={@total_count} status="all" selected={@status_filter == "all"} />
        <.stat_card label="Proposed" value={@pending_count} status="proposed" color="var(--amber)" selected={@status_filter == "proposed"} />
        <.stat_card label="Approved" value={@approved_count} status="approved" color="var(--green)" selected={@status_filter == "approved"} />
        <.stat_card label="Deprecated" value={@deprecated_count} status="deprecated" color="var(--muted)" selected={@status_filter == "deprecated"} />
        <.stat_card label="Rejected" value={@rejected_count} status="rejected" color="var(--red)" selected={@status_filter == "rejected"} />
      </div>

      <!-- Memory List + Detail Panel -->
      <div class="governance-layout">
        <!-- Sidebar: Memory list -->
        <div class="governance-list">
          <div class="governance-toolbar">
            <div class="page-toolbar-actions">
              <%= if selected_memory_count(@memories, @selected_memory_ids) > 0 do %>
                <button phx-click="approve-selected" class="btn btn-primary compact-button">
                  ✓ Approve selected (<%= selected_memory_count(@memories, @selected_memory_ids) %>)
                </button>
                <button phx-click="clear-selection" class="btn btn-ghost compact-button">Clear</button>
              <% end %>
            </div>
            <button phx-click="refresh" class="btn btn-ghost compact-button">
              ↻ Refresh
            </button>
            <%= if @pending_count > 0 do %>
              <button
                phx-click="approve-all-proposed"
                class="btn btn-primary compact-button"
                title={"Approve all #{@pending_count} proposed memories"}
              >
                ✓ Approve All (<%= @pending_count %>)
              </button>
            <% end %>
          </div>

          <%= if Enum.empty?(@memories) do %>
            <div class="card empty-card">
              <%= if assigns[:loading] == true do %>
                <div class="loading-state" role="status">Loading memories</div>
              <% else %>
              <div class="empty-state">
                <div class="empty-state-icon">◈</div>
                <p class="empty-state-title">
                  <%= case @status_filter do %>
                    <% "proposed" -> %>No memories pending approval
                    <% "all" -> %>No memories found
                    <% "parse_error" -> %>No quarantined memories
                    <% "review" -> %>No memories need review
                    <% status -> %>No <%= status %> memories
                  <% end %>
                </p>
              </div>
              <% end %>
            </div>
          <% else %>
            <%= for memory <- @memories do %>
              <div
                phx-click={if @selected_memory && @selected_memory.id == memory.id, do: "deselect-memory", else: "select-memory"}
                phx-keydown="select-memory-key"
                phx-key="Enter"
                phx-value-id={memory.id}
                class={"tool-row #{if needs_human_review?(memory), do: "memory-review-needed"} #{if @selected_memory && @selected_memory.id == memory.id, do: "selected"}"}
                role="button"
                tabindex="0"
                aria-pressed={to_string(@selected_memory && @selected_memory.id == memory.id)}
              >
                <div style="display: flex; align-items: center; gap: 10px;">
                  <input class="selection-checkbox" type="checkbox" checked={MapSet.member?(@selected_memory_ids, memory.id)} phx-click="toggle-select" phx-value-id={memory.id} phx-stopPropagation aria-label={"Select #{memory.title}"} />
                  <span class={"status-dot status-#{memory.status}"}></span>
                  <span class="category-badge"><%= memory.kind %></span>
                  <span style="flex: 1; font-weight: 500; font-size: 0.88rem; color: var(--text);"><%= memory.title %></span>
                  <%= if needs_human_review?(memory) do %>
                    <span class="category-badge" style="background: var(--amber-glow); color: var(--amber); border-color: rgba(201, 168, 106, 0.35); font-weight: 600;" title="This memory needs human review">
                      Needs human review
                    </span>
                  <% end %>
                  <span style="font-size: 0.7rem; color: var(--muted); font-family: var(--font-mono);">
                    I<%= memory.importance %>
                  </span>
                  <%= if count = get_conflict_count(@conflict_alerts, memory.id) do %>
                    <span class="conflict-badge" title={"#{count} conflict(s) detected"} style="display: inline-flex; align-items: center; gap: 3px; padding: 2px 6px; border-radius: 4px; background: rgba(217, 119, 6, 0.12); color: #d97706; font-size: 0.65rem; font-weight: 600; line-height: 1;">
                      ⚠ <%= count %>
                    </span>
                  <% end %>
                  <%= if creator = creator_label(memory) do %>
                    <span style="font-size: 0.68rem; color: var(--muted);" title={"Created by #{creator}"}>
                      <%= creator %>
                    </span>
                  <% end %>
                  <span style="font-size: 0.7rem; color: var(--muted);">
                    <%= memory.scope_path %>
                  </span>
                </div>
                <%= if memory.summary && memory.summary != "" do %>
                  <div style="font-size: 0.78rem; color: var(--text-dim); margin-top: 4px; margin-left: 22px;">
                    <%= String.slice(memory.summary, 0, 120) %><%= if String.length(memory.summary || "") > 120, do: "..." %>
                  </div>
                <% end %>
                <%= if memory.status == "proposed" do %>
                  <div style="display: flex; gap: 6px; margin-top: 8px; margin-left: 22px;">
                    <button
                      phx-click="approve"
                      phx-value-id={memory.id}
                      phx-stopPropagation
                      class="btn btn-primary"
                      style="padding: 4px 12px; font-size: 0.68rem;"
                      title="Approve and save this memory to YAML"
                    >
                      ✓ Approve & Save
                    </button>
                    <button
                      phx-click="reject"
                      phx-value-id={memory.id}
                      phx-stopPropagation
                      class="btn btn-danger"
                      style="padding: 4px 12px; font-size: 0.68rem;"
                      title="Reject this memory"
                    >
                      ✗ Reject
                    </button>
                  </div>
                <% end %>
                <%= if memory.status == "approved" do %>
                  <div style="display: flex; gap: 6px; margin-top: 8px; margin-left: 22px;">
                    <button
                      phx-click="mark-stale"
                      phx-value-id={memory.id}
                      phx-stopPropagation
                      class="btn btn-ghost"
                      style="padding: 4px 12px; font-size: 0.68rem;"
                      title="Mark this memory as stale"
                    >
                      ⟳ Mark Stale
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Detail panel -->
        <%= if @selected_memory do %>
          <div class="card governance-detail governance-detail-expand" style="padding: 20px;">
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
              <div style="display: flex; gap: 8px; align-items: center;">
                <span class={"status-dot status-#{@selected_memory.status}"}></span>
                <span class="category-badge"><%= @selected_memory.kind %></span>
                <span style="font-size: 0.7rem; color: var(--muted); font-family: var(--font-mono);">I<%= @selected_memory.importance %></span>
              </div>
              <div style="display: flex; gap: 6px;">
                <%= if @selected_memory.status == "proposed" do %>
                  <button phx-click="approve" phx-value-id={@selected_memory.id} class="btn btn-primary" style="padding: 6px 14px; font-size: 0.72rem;" title="Approve and save this memory to YAML">
                    ✓ Approve & Save
                  </button>
                  <button phx-click="reject" phx-value-id={@selected_memory.id} class="btn btn-danger" style="padding: 6px 14px; font-size: 0.72rem;">
                    ✗ Reject
                  </button>
                <% end %>
                <%= if @selected_memory.status == "approved" do %>
                  <button phx-click="mark-stale" phx-value-id={@selected_memory.id} class="btn btn-ghost" style="padding: 6px 14px; font-size: 0.72rem;">
                    ⟳ Mark Stale
                  </button>
                <% end %>
              </div>
            </div>

            <h3 style="font-size: 1rem; margin: 0 0 12px 0; color: var(--text);"><%= @selected_memory.title %></h3>

            <div style="margin-bottom: 12px;">
              <span style="font-family: var(--font-mono); font-size: 0.65rem; color: var(--muted);">ID: </span>
              <code style="font-size: 0.72rem;"><%= @selected_memory.id %></code>
            </div>

            <div style="margin-bottom: 12px;">
              <span style="font-family: var(--font-mono); font-size: 0.65rem; color: var(--muted);">Scope: </span>
              <code style="font-size: 0.72rem;"><%= @selected_memory.scope_path %></code>
            </div>

            <div style="display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 12px; font-size: 0.72rem; color: var(--muted);">
              <%= if creator = creator_label(@selected_memory) do %>
                <span>
                  Created by:
                  <strong style="color: var(--text);"><%= creator %></strong>
                  <%= if type = creator_type(@selected_memory) do %>
                    <span class="category-badge" style="margin-left: 4px;"><%= type %></span>
                  <% end %>
                </span>
              <% end %>
              <%= if @selected_memory.audience do %>
                <span>Audience: <strong style="color: var(--text);"><%= @selected_memory.audience %></strong></span>
              <% end %>
              <%= if @selected_memory.visibility do %>
                <span>Visibility: <strong style="color: var(--text);"><%= @selected_memory.visibility %></strong></span>
              <% end %>
              <%= if @selected_memory.team do %>
                <span>Team: <strong style="color: var(--text);"><%= @selected_memory.team %></strong></span>
              <% end %>
              <%= if @selected_memory.project do %>
                <span>Project: <strong style="color: var(--text);"><%= @selected_memory.project %></strong></span>
              <% end %>
            </div>

            <%= if tags = memory_tags(@selected_memory) do %>
              <div style="display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 12px;">
                <%= for tag <- tags do %>
                  <span class="category-badge"><%= tag %></span>
                <% end %>
              </div>
            <% end %>

            <%= if @selected_memory.summary do %>
              <div style="margin-bottom: 16px; padding: 10px; background: var(--bg); border-radius: var(--radius); font-size: 0.82rem; color: var(--text-dim); line-height: 1.5;">
                <%= @selected_memory.summary %>
              </div>
            <% end %>

            <%= if @selected_memory.content do %>
              <div style="margin-bottom: 16px; display: flex; flex-direction: column; flex: 1 1 auto; min-height: 0;">
                <div style="font-family: var(--font-mono); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); margin-bottom: 6px;">Content</div>
                <pre style="background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius); padding: 12px; font-size: 0.75rem; line-height: 1.5; flex: 1 1 auto; min-height: 200px; overflow-y: auto; color: var(--text-dim);"><%= @selected_memory.content %></pre>
              </div>
            <% end %>

            <%= if flags = decode_auditor_flags(@selected_memory.auditor_flags) do %>
              <div style="margin-bottom: 16px; padding: 10px 12px; background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius);">
                <div style="font-family: var(--font-mono); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); margin-bottom: 8px;">LLM Audit</div>
                <div style="display: flex; gap: 12px; flex-wrap: wrap; font-size: 0.72rem; color: var(--muted); margin-bottom: 6px;">
                  <%= if flags["audit_verdict"] || flags["auditVerdict"] do %>
                    <span>Verdict: <strong style="color: var(--text);"><%= flags["audit_verdict"] || flags["auditVerdict"] %></strong></span>
                  <% end %>
                  <%= if flags["quality_score"] || flags["qualityScore"] do %>
                    <span>Quality: <strong style="color: var(--text);"><%= flags["quality_score"] || flags["qualityScore"] %></strong></span>
                  <% end %>
                  <%= if flags["audited_at"] || flags["auditedAt"] do %>
                    <span>Audited: <%= format_datetime_string(flags["audited_at"] || flags["auditedAt"]) %></span>
                  <% end %>
                  <%= if @selected_memory.status == "proposed" &&
                          (Map.get(flags, "needs_human_review") ||
                             Map.get(flags, "audit_error_count", 0) > 0) do %>
                    <span style="color: #d97706; font-weight: 600;">Needs review</span>
                  <% end %>
                </div>
                <%= if reasoning = flags["reasoning"] || flags["audit_reasoning"] do %>
                  <div style="font-size: 0.78rem; color: var(--text-dim); line-height: 1.45;"><%= reasoning %></div>
                <% end %>
              </div>
            <% end %>

            <%= if @selected_memory && Map.has_key?(@conflict_alerts, @selected_memory.id) do %>
              <div style="margin-bottom: 16px;">
                <div style="font-family: var(--font-mono); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; color: #d97706; margin-bottom: 6px;">⚠ Conflict Alerts</div>
                <%= for flag <- @conflict_alerts[@selected_memory.id] do %>
                  <div style="padding: 8px 12px; margin-bottom: 6px; background: rgba(217, 119, 6, 0.08); border: 1px solid rgba(217, 119, 6, 0.2); border-radius: var(--radius); font-size: 0.75rem; color: var(--text-dim);">
                    <div style="display: flex; gap: 8px; align-items: center; margin-bottom: 4px;">
                      <span style="font-weight: 600; text-transform: uppercase; font-size: 0.65rem;"><%= flag.type %></span>
                      <span style="font-size: 0.6rem; color: var(--muted);">·</span>
                      <span style="font-size: 0.65rem;">confidence: <%= flag.confidence %></span>
                    </div>
                    <div><%= flag.reason %></div>
                  </div>
                <% end %>
              </div>
            <% end %>

            <div style="display: flex; gap: 8px; flex-wrap: wrap;">
              <div style="font-size: 0.72rem; color: var(--muted);">
                Created: <%= format_datetime(@selected_memory.created_at) %>
              </div>
              <div style="font-size: 0.72rem; color: var(--muted);">
                Updated: <%= format_datetime(@selected_memory.updated_at) %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %H:%M")
  defp format_datetime(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%b %d, %H:%M")

  defp format_datetime_string(nil), do: "N/A"

  defp format_datetime_string(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> format_datetime(dt)
      _ -> iso
    end
  end

  defp format_datetime_string(_), do: "N/A"

  defp creator_label(memory) do
    cond do
      is_binary(memory.created_by_agent) and memory.created_by_agent != "" ->
        memory.created_by_agent

      true ->
        case decode_created_by(memory.created_by_json) do
          %{"id" => id} when is_binary(id) and id != "" -> id
          _ -> nil
        end
    end
  end

  defp creator_type(memory) do
    case decode_created_by(memory.created_by_json) do
      %{"type" => type} when is_binary(type) and type != "" -> type
      _ -> nil
    end
  end

  defp decode_created_by(nil), do: nil

  defp decode_created_by(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp decode_created_by(_), do: nil

  defp decode_auditor_flags(nil), do: nil

  defp decode_auditor_flags(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, flags} when is_map(flags) and map_size(flags) > 0 ->
        # Atom keys from older writes — normalize to strings
        Map.new(flags, fn
          {k, v} when is_atom(k) -> {Atom.to_string(k), v}
          {k, v} -> {k, v}
        end)

      _ ->
        nil
    end
  end

  defp decode_auditor_flags(_), do: nil

  defp needs_human_review?(memory) do
    memory.status == "proposed" and has_review_flags?(memory)
  end

  defp has_review_flags?(memory) do
    case decode_auditor_flags(memory.auditor_flags) do
      flags when is_map(flags) ->
        review_flag?(flags["needs_human_review"] || flags["needsHumanReview"]) or
          audit_errors?(flags["audit_error_count"] || flags["auditErrorCount"])

      _ ->
        false
    end
  end

  defp review_flag?(value), do: value in [true, 1, "1", "true", "TRUE"]

  defp audit_errors?(value) when is_integer(value), do: value > 0
  defp audit_errors?(value) when is_float(value), do: value > 0

  defp audit_errors?(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} -> count > 0
      _ -> false
    end
  end

  defp audit_errors?(_), do: false

  defp memory_tags(memory) do
    case parse_tags_json(memory.tags_json) do
      [] -> nil
      tags -> tags
    end
  end

  defp parse_tags_json(nil), do: []

  defp parse_tags_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, tags} when is_list(tags) -> tags
      _ -> []
    end
  end

  defp parse_tags_json(_), do: []

  defp get_conflict_count(alerts, id) when is_map(alerts) do
    case Map.fetch(alerts, id) do
      {:ok, flags} when is_list(flags) and flags != [] -> length(flags)
      _ -> nil
    end
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :status, :string, required: true
  attr :color, :string, default: nil
  attr :selected, :boolean, default: false

  defp stat_card(assigns) do
    ~H"""
    <button type="button" phx-click="filter-status" phx-value-status={@status} class={"stat-card-button #{if @selected, do: "active"}"} style={if @color, do: "border-left-color: #{@color};", else: nil} aria-pressed={@selected}>
      <div class="stat-card-label"><%= @label %></div>
      <div class="stat-card-value"><%= @value || 0 %></div>
    </button>
    """
  end
end

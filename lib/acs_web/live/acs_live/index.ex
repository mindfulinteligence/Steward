defmodule AcsWeb.AcsLive.Index do
  @moduledoc """
  LiveView dashboard for Agent Coordination System.
  Shows tasks, locked files, and agent status.
  """

  use AcsWeb, :live_view
  alias Acs
  alias Acs.Memory.Indexer

  def on_mount(_params, _session, socket) do
    # Don't use get_connect_info - it fails on push_navigate reconnections
    # Let handle_params set current_path from URL instead
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @getting_started_dismissed_key "acs.getting_started_dismissed"
  @dashboard_seen_key "acs.dashboard_seen"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        tasks: [],
        locked_files: [],
        agent_status: %{},
        selected_status: "all",
        loading: connected?(socket),
        pending_requests_count: Acs.MCP.ToolRequests.pending_count(),
        memory_review_count: 0,
        todo_tasks_count: 0,
        getting_started_dismissed: getting_started_dismissed?(socket),
        mcp_endpoints: AcsWeb.McpUrls.endpoints(),
        chat_system_prompt: AcsWeb.McpUrls.chat_system_prompt(:always),
        chat_system_prompt_opt_in: AcsWeb.McpUrls.chat_system_prompt(:opt_in),
        coding_system_prompt: AcsWeb.McpUrls.coding_system_prompt(),
        project_setup_prompt: AcsWeb.McpUrls.project_setup_prompt()
      )

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(AcsWeb.PubSub, "acs")
        push_event(socket, "store", %{key: @dashboard_seen_key, value: "1"})
        send(self(), :load_data)
        socket
      else
        load_data(socket)
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, url, socket) do
    uri = URI.parse(url)
    path = uri.path || "/"
    selected_status = Map.get(params, "status", socket.assigns.selected_status)

    selected_status =
      if selected_status in ~w(all todo claimed in_progress done),
        do: selected_status,
        else: "all"

    {:noreply,
     socket
     |> assign(current_path: path, selected_status: selected_status)
     |> load_data()
     |> assign(
       mcp_endpoints: AcsWeb.McpUrls.endpoints(uri),
       project_setup_prompt: AcsWeb.McpUrls.project_setup_prompt(uri)
     )}
  end

  @impl true
  def handle_event("filter-status", %{"status" => status}, socket) do
    socket = assign(socket, selected_status: status) |> load_data()
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    socket = load_data(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("dismiss-getting-started", _, socket) do
    {:noreply,
     socket
     |> assign(getting_started_dismissed: true)
     |> push_event("store", %{key: @getting_started_dismissed_key, value: "1"})}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info({:task_created, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:task_claimed, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:task_done, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:task_updated, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:task_released, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:task_status_changed, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:file_locked, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:file_unlocked, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:agent_updated, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:agent_removed, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:acs_reset, _payload}, socket) do
    socket = put_flash(socket, :info, "Steward data was reset by another session.")
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:tool_request_created, :tool_request_approved, :tool_request_rejected] do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_data(socket) do
    status_filter = socket.assigns.selected_status

    tasks =
      if status_filter == "all" do
        Acs.list_tasks()
      else
        Acs.list_tasks(status_filter)
      end

    agent_status = Acs.get_present_status()
    locked_files = Acs.get_locked_files()

    assign(socket,
      tasks: tasks,
      locked_files: locked_files,
      agent_status: agent_status,
      pending_requests_count: Acs.MCP.ToolRequests.pending_count(),
      memory_review_count: Indexer.count_memories_needing_review(socket.assigns.current_org, []),
      todo_tasks_count: length(Acs.list_tasks("todo")),
      loading: false
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="acs-dashboard">
      <section class="account-intro animate-in" aria-labelledby="dashboard-title">
        <p class="account-kicker" style="font-size: 0.5rem; margin-bottom: 6px;"><span>Workspace</span> / Live operations</p>
        <h1 id="dashboard-title" style="font-size: 1.3rem; margin-bottom: 6px;">Workspace overview</h1>
        <p style="font-size: 0.82rem;">Monitor connected agents, active work, and file coordination in one place.</p>
      </section>

      <section class="review-queue" aria-label="Review queue">
        <.link navigate="/tools/requests" class="review-queue-card">
          <span>
            <span class="review-queue-card-label">Pending requests</span>
            <span class="review-queue-card-meta">Needs a decision</span>
          </span>
          <span class="review-queue-card-count"><%= assigns[:pending_requests_count] || 0 %></span>
        </.link>
        <.link navigate="/?status=todo" class="review-queue-card">
          <span>
            <span class="review-queue-card-label">Tasks to pick up</span>
            <span class="review-queue-card-meta">Waiting for an agent</span>
          </span>
          <span class="review-queue-card-count"><%= assigns[:todo_tasks_count] || 0 %></span>
        </.link>
        <.link navigate="/memories?view=review" class="review-queue-card">
          <span>
            <span class="review-queue-card-label">Memory review</span>
            <span class="review-queue-card-meta">Human attention needed</span>
          </span>
          <span class="review-queue-card-count"><%= assigns[:memory_review_count] || 0 %></span>
        </.link>
      </section>

      <details
        id="mcp-connectors"
        class="mcp-connectors animate-in delay-1"
        open={show_getting_started?(@agent_status, @tasks, @locked_files, @getting_started_dismissed)}
      >
        <summary class="mcp-connectors-summary">
          <span class="mcp-connectors-summary-main">
            <span class="account-kicker">Connect</span>
            <span class="mcp-connectors-title">Agent URLs</span>
          </span>
          <span class="mcp-connectors-summary-meta text-dim">Coding · Chat · Copy</span>
        </summary>

        <div class="mcp-connectors-body">
          <div class="card-elevated" style="padding: 16px; margin-bottom: 16px;">
            <p class="mcp-connector-step-label">Fast project setup</p>
            <p class="text-dim" style="font-size: 0.8rem; margin: 6px 0 12px;">
              Open your coding agent in the project, paste one prompt, and let it merge the MCP and agent files for this organization.
            </p>
            <button
              id="copy-project-setup-prompt"
              type="button"
              class="btn btn-primary"
              data-copy-target="project-setup-prompt"
              data-copy-status="project-setup-prompt-copy-status"
              data-copy-label="Copy project setup prompt"
              data-copy-success="Project setup prompt copied."
            >
              Copy project setup prompt
            </button>
            <textarea id="project-setup-prompt" class="sr-only" readonly tabindex="-1" aria-hidden="true"><%= @project_setup_prompt %></textarea>
            <p id="project-setup-prompt-copy-status" class="form-hint sr-only" aria-live="polite"></p>
          </div>

          <p class="mcp-connectors-note text-dim">
            Two steps each: copy the connector URL, then paste the instructions into
            <code>AGENTS.md</code> (coding) or Claude system prompt (chat).
            OAuth API identifier stays <code>/mcp/sse</code>.
            Chat: <code>steward_ask</code>, <code>steward_write</code>, and
            <code>steward_work</code> are always loaded. Call them directly; never use find tools /
            <code>tool_search</code>. Choose Always Active or Opt In for the Claude paste.
            Reconnect after deploy to refresh the cached list. Coding keeps the fine-grained tool names.
          </p>

          <div class="mcp-connectors-list">
            <%= for endpoint <- @mcp_endpoints do %>
              <% prompt_variants =
                   case endpoint.audience do
                     "coding" ->
                       [
                         {@coding_system_prompt, "coding", "Copy this into your AGENTS.md",
                          "Copy into AGENTS.md", "Paste into AGENTS.md / agent rules"}
                       ]

                     "chat" ->
                       [
                         {@chat_system_prompt, "always", "Always Active — use when needed",
                          "Copy Always Active", "Paste into Claude system prompt"},
                         {@chat_system_prompt_opt_in, "opt-in",
                          "Opt In — ask before using Steward", "Copy Opt In",
                          "Paste into Claude system prompt"}
                       ]

                     _ ->
                       []
                   end %>
              <article class={"mcp-connector-card mcp-connector-card--#{endpoint.audience}"}>
                <header class="mcp-connector-card-header">
                  <div class="mcp-connector-heading">
                    <strong id={"#{endpoint.id}-title"}><%= endpoint.title %></strong>
                    <span class={"badge-status badge-#{endpoint.audience}"}><%= endpoint.audience %></span>
                  </div>
                  <p class="mcp-connector-clients"><%= endpoint.clients %></p>
                </header>

                <div class="mcp-connector-step">
                  <span class="mcp-connector-step-num" aria-hidden="true">1</span>
                  <div class="mcp-connector-step-body">
                    <p class="mcp-connector-step-label">Connector URL</p>
                    <div class="mcp-url-row">
                      <code id={endpoint.id} class="mcp-url-value"><%= endpoint.url %></code>
                      <button
                        type="button"
                        class="btn btn-copy"
                        data-copy-value={endpoint.url}
                        data-copy-label="Copy URL"
                        data-copy-success="Copied."
                      >
                        Copy URL
                      </button>
                    </div>
                  </div>
                </div>

                <%= if prompt_variants != [] do %>
                  <div class="mcp-connector-step mcp-connector-step--prompt">
                    <span class="mcp-connector-step-num" aria-hidden="true">2</span>
                    <div class="mcp-connector-step-body">
                      <p class="mcp-connector-step-label"><%= elem(hd(prompt_variants), 4) %></p>
                      <%= for {prompt, variant, prompt_label, prompt_button, _dest} <- prompt_variants do %>
                        <% prompt_id = "mcp-#{endpoint.audience}-#{variant}-system-prompt" %>
                        <% prompt_btn_id = "copy-#{endpoint.audience}-#{variant}-system-prompt" %>
                        <% prompt_status_id = "mcp-#{endpoint.audience}-#{variant}-prompt-copy-status" %>
                        <div class="mcp-prompt-copy">
                          <p class="mcp-prompt-copy-label"><%= prompt_label %></p>
                          <button
                            id={prompt_btn_id}
                            type="button"
                            class="btn btn-copy btn-copy-prompt"
                            data-copy-target={prompt_id}
                            data-copy-status={prompt_status_id}
                            data-copy-label={prompt_button}
                            data-copy-success={"Copied #{prompt_button}."}
                          >
                            <%= prompt_button %>
                          </button>
                        </div>
                        <textarea
                          id={prompt_id}
                          class="sr-only"
                          readonly
                          tabindex="-1"
                          aria-hidden="true"
                        ><%= prompt %></textarea>
                        <p id={prompt_status_id} class="form-hint sr-only" aria-live="polite"></p>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <p id={endpoint.copy_status_id} class="form-hint sr-only" aria-live="polite"></p>
              </article>
            <% end %>
          </div>
        </div>
      </details>

      <%= if show_getting_started?(@agent_status, @tasks, @locked_files, @getting_started_dismissed) do %>
        <section id="getting-started" class="card animate-in delay-1" style="padding: 28px;" aria-labelledby="getting-started-title">
          <div class="account-card-heading">
            <div>
              <p class="account-kicker">Getting started</p>
              <h2 id="getting-started-title">Connect your first agent</h2>
            </div>
            <div style="display: flex; align-items: center; gap: 12px;">
              <span class="coordinate-mark" aria-hidden="true">01 / 03</span>
              <button
                id="dismiss-getting-started"
                type="button"
                phx-click="dismiss-getting-started"
                class="btn btn-ghost"
                aria-label="Dismiss getting started"
              >
                Dismiss
              </button>
            </div>
          </div>
          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px;">
            <div class="card-elevated" style="padding: 16px;">
              <strong>1. Configure MCP</strong>
              <p class="text-dim" style="font-size: 0.8rem; margin-top: 6px;">
                Open <a href="#mcp-connectors" class="text-accent">Agent URLs</a> above and choose <strong>Copy project setup prompt</strong>. Paste it into a coding agent opened at your project root.
              </p>
            </div>
            <div class="card-elevated" style="padding: 16px;">
              <strong>2. Verify tools</strong>
              <p class="text-dim" style="font-size: 0.8rem; margin-top: 6px;">
                Confirm the tools your agent can use. Chat agents should call core tools
                directly (no find-tools warmup). Coding agents claim a task before editing.
              </p>
              <.link navigate="/tools" class="text-accent" style="display: inline-block; font-size: 0.8rem; margin-top: 8px;">View tools →</.link>
            </div>
            <div class="card-elevated" style="padding: 16px;">
              <strong>3. Start a task</strong>
              <p class="text-dim" style="font-size: 0.8rem; margin-top: 6px;">Agent activity, tasks, and file locks will appear here automatically.</p>
            </div>
          </div>
        </section>
      <% end %>

      <!-- Agent Status Section -->
      <section>
        <div class="section-header">
          <span class="status-dot working"></span>
          <h2 class="section-title">Active Agents</h2>
          <span class="section-count">(<%= map_size(@agent_status) %>)</span>
        </div>

        <%= if Enum.empty?(@agent_status) do %>
          <div class="card empty-card">
            <%= if assigns[:loading] == true do %>
              <div class="loading-state" role="status">Loading agents</div>
            <% else %>
            <div class="empty-state">
              <div class="empty-state-icon">◉</div>
              <p class="empty-state-title">No active agents</p>
              <p class="empty-state-desc">Agents will appear here when they connect to the Steward server</p>
            </div>
            <% end %>
          </div>
        <% else %>
          <div class="agents-grid">
            <%= for {agent_id, status} <- @agent_status do %>
              <div class="agent-card">
                <div class="agent-header">
                  <span class={status_dot_class(status.status)}></span>
                  <span class="agent-name"><%= agent_id %></span>
                  <span class={status_badge_class(status.status)}><%= status_label(status.status) %></span>
                </div>

                <%= if status.task do %>
                  <div class="agent-task-box">
                    <div class="agent-task-label">Current Task</div>
                    <div class="agent-task-title" title={status.task.title}><%= status.task.title %></div>
                    <%= if status.task.description do %>
                      <div class="agent-task-desc"><%= status.task.description %></div>
                    <% end %>
                    <div style="margin-top: 8px; display: flex; align-items: center; gap: 8px;">
                      <span class={"badge-status badge-#{status.task.status}"}><%= status.task.status %></span>
                    </div>
                  </div>
                <% else %>
                  <div class="agent-task-box">
                    <div class="agent-task-label">Current Task</div>
                    <div style="color: var(--muted); font-size: 0.85rem; font-style: italic;">No active task</div>
                  </div>
                <% end %>

                <%= if status.application || status.component do %>
                  <div style="margin-bottom: 12px; display: flex; gap: 16px;">
                    <%= if status.application do %>
                      <div>
                        <div class="agent-task-label">Application</div>
                        <div style="font-size: 0.8rem; color: var(--text);"><%= status.application %></div>
                      </div>
                    <% end %>
                    <%= if status.component do %>
                      <div>
                        <div class="agent-task-label">Component</div>
                        <div style="font-size: 0.8rem; color: var(--text-dim);"><%= status.component %></div>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if not Enum.empty?(status.locked_files) do %>
                  <div class="agent-locks">
                    <div class="agent-locks-label">Locked Files</div>
                    <div style="display: flex; flex-wrap: wrap; gap: 6px;">
                      <%= for file <- status.locked_files do %>
                        <span class="lock-file-tag" title={file}><%= Path.basename(file) %></span>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </section>

      <!-- Tasks & Locks Grid -->
      <div class="two-col-grid">

        <!-- Tasks Column -->
        <section>
          <div class="card" style="padding: 24px;">
            <div class="section-header">
              <h2 class="section-title">Tasks</h2>
              <span class="section-count">(<%= length(@tasks) %>)</span>
            </div>

            <div class="filter-tabs" style="margin-bottom: 20px;">
              <%= for status <- ["all", "todo", "claimed", "in_progress", "done"] do %>
                <button
                  phx-click="filter-status"
                  phx-value-status={status}
                  class={if @selected_status == status, do: "filter-tab active", else: "filter-tab"}
                >
                  <%= String.capitalize(status) %>
                </button>
              <% end %>
            </div>

            <div class="scroll-area">
              <%= if Enum.empty?(@tasks) do %>
                <div class="empty-state empty-card">
                  <%= if assigns[:loading] == true do %>
                    <div class="loading-state" role="status">Loading tasks</div>
                  <% else %>
                  <div class="empty-state-icon">○</div>
                  <p class="empty-state-title">
                    <%= if @selected_status == "all", do: "No tasks yet", else: "No #{@selected_status |> String.replace("_", " ")} tasks" %>
                  </p>
                  <p class="empty-state-desc">
                    <%= if @selected_status == "all", do: "Tasks appear here when connected agents create work.", else: "No tasks match the current status filter." %>
                  </p>
                  <%= if @selected_status != "all" do %>
                    <button phx-click="filter-status" phx-value-status="all" class="btn btn-ghost" style="margin-top: 14px;">Clear filter</button>
                  <% end %>
                  <% end %>
                </div>
              <% else %>
                <div style="display: flex; flex-direction: column; gap: 10px;">
                  <%= for task <- @tasks do %>
                    <div class={if task.event_count && task.event_count > 1, do: "task-item priority", else: "task-item"}>
                      <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 12px;">
                        <div style="flex: 1; min-width: 0;">
                          <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 4px;">
                            <span style="font-size: 0.9rem; font-weight: 500; color: var(--text);" class="truncate"><%= task.title %></span>
                            <%= if task.event_count && task.event_count > 1 do %>
                              <span style="display: inline-flex; align-items: center; justify-content: center; min-width: 20px; height: 18px; padding: 0 6px; background: var(--amber-glow); color: var(--amber); border-radius: 10px; font-family: var(--font-mono); font-size: 0.65rem; font-weight: 600;">
                                ×<%= task.event_count %>
                              </span>
                            <% end %>
                          </div>
                          <%= if task.description do %>
                            <p style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 6px; line-height: 1.4;" class="line-clamp-2"><%= task.description %></p>
                          <% end %>
                          <div style="display: flex; align-items: center; gap: 8px; font-size: 0.72rem; color: var(--muted);">
                            <span style="font-family: var(--font-mono);"><%= task.created_by_agent %></span>
                            <span>·</span>
                            <span class="timestamp"><%= format_datetime(task.inserted_at) %></span>
                          </div>
                        </div>
                        <span class={"badge-status badge-#{task.status}"}><%= task.status %></span>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </section>

        <!-- Locked Files Column -->
        <section>
          <div class="card" style="padding: 24px;">
            <div class="section-header">
              <h2 class="section-title">Locked Files</h2>
              <span class="section-count">(<%= length(@locked_files) %>)</span>
            </div>

            <div class="scroll-area">
              <%= if Enum.empty?(@locked_files) do %>
                <div class="empty-state empty-card">
                  <%= if assigns[:loading] == true do %>
                    <div class="loading-state" role="status">Loading locks</div>
                  <% else %>
                  <div class="empty-state-icon">🔓</div>
                  <p class="empty-state-title">No files locked</p>
                  <p class="empty-state-desc">File locks will appear here when agents lock files</p>
                  <% end %>
                </div>
              <% else %>
                <div style="display: flex; flex-direction: column; gap: 10px;">
                  <%= for lock <- @locked_files do %>
                    <div class="lock-item">
                      <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; margin-bottom: 8px;">
                        <code class="mono" style="font-size: 0.78rem; color: var(--text); word-break: break-all; flex: 1;"><%= lock.file_path %></code>
                        <span style="font-size: 0.72rem; color: var(--muted); shrink: 0;"><%= lock.locked_by_agent %></span>
                      </div>
                      <div style="display: flex; align-items: center; gap: 12px; font-size: 0.72rem; color: var(--muted);">
                        <span>
                          <span style="color: var(--text-dim);">Locked:</span>
                          <span class="timestamp"><%= if lock.locked_at, do: format_datetime(lock.locked_at), else: "N/A" %></span>
                        </span>
                        <span>·</span>
                        <span>
                          <span style="color: var(--text-dim);">Expires:</span>
                          <span class="timestamp"><%= if lock.auto_release_at, do: format_datetime(lock.auto_release_at), else: "N/A" %></span>
                        </span>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </section>

      </div>
    </div>
    """
  end

  defp show_getting_started?(agent_status, tasks, locked_files, dismissed) do
    not dismissed and Enum.empty?(agent_status) and Enum.empty?(tasks) and
      Enum.empty?(locked_files)
  end

  defp getting_started_dismissed?(socket) do
    connected?(socket) and
      get_connect_params(socket)["getting_started_dismissed"] in ["1", "true"]
  end

  # Status helpers
  defp status_dot_class("working"), do: "status-dot working"
  defp status_dot_class(_), do: "status-dot sleeping"

  defp status_badge_class("working"), do: "badge badge-working"
  defp status_badge_class(_), do: "badge badge-sleeping"

  defp status_label("working"), do: "Working"
  defp status_label(_), do: "Sleeping"

  # Date formatting
  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %H:%M")
  defp format_datetime(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%b %d, %H:%M")
end

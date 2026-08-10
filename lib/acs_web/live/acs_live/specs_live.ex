defmodule AcsWeb.AcsLive.SpecsLive do
  @moduledoc """
  LiveView for human governance of specs (code) and documents (non-code).

  Provides:
  - List all specs/documents with status filters (proposed, approved, deprecated, etc.)
  - Full-document popup viewer
  - Approve/reject/delete actions
  - Stats summary
  """

  use AcsWeb, :live_view
  require Logger

  alias Acs.Specs.Entry
  alias Acs.Specs.Lineage
  alias Acs.Specs.Loader
  alias Acs.Specs.Search
  alias Acs.Abac

  def on_mount(_params, _session, socket) do
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(AcsWeb.PubSub, "acs")

    socket =
      socket
      |> assign(
        specs: [],
        stats: %{},
        selected_spec: nil,
        selected_spec_keys: MapSet.new(),
        replacement_candidates: [],
        status_filter: nil,
        search_query: "",
        loading: connected?(socket)
      )

    socket =
      if connected?(socket) do
        send(self(), :load_data)
        socket
      else
        load_data(socket)
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("select-spec", %{"path" => _app_path}, socket) do
    # Selected via app|path compound key
    {:noreply, socket}
  end

  @impl true
  def handle_event("select-spec-detail", %{"app" => app, "id" => id}, socket) do
    selected = socket.assigns.selected_spec

    if selected && selected.app == app && selected.id == id do
      {:noreply, assign(socket, selected_spec: nil)}
    else
      entry =
        Enum.find(socket.assigns.specs, &(&1.app == app && &1.id == id)) ||
          case Loader.load(app, id) do
            {:ok, e} -> e
            _ -> nil
          end

      {:noreply, assign(socket, selected_spec: entry)}
    end
  end

  @impl true
  def handle_event("deselect-spec", _, socket) do
    {:noreply, assign(socket, selected_spec: nil)}
  end

  @impl true
  def handle_event("approve-spec", %{"app" => app, "id" => id}, socket) do
    case Loader.load(app, id) do
      {:ok, entry} ->
        if Abac.can_edit?(viewer_abac(socket), entry) do
          now = DateTime.utc_now() |> DateTime.to_iso8601()
          updated = %{entry | status: "approved", approved_by: "human", updated_at: now}
          updated = %{updated | spec_hash: Entry.compute_spec_hash(updated)}

          case Loader.save(updated) do
            :ok ->
              socket =
                socket
                |> put_flash(:info, "Spec '#{app}/#{id}' approved ✓")
                |> assign(selected_spec: nil)
                |> load_data()

              {:noreply, socket}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Could not approve this document. Try again.")}
          end
        else
          {:noreply,
           put_flash(
             socket,
             :error,
             "Access denied: cannot edit specs at or above your clearance"
           )}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not load this document. Try again.")}
    end
  end

  @impl true
  def handle_event("reject-spec", %{"app" => app, "id" => id}, socket) do
    case Loader.load(app, id) do
      {:ok, entry} ->
        if Abac.can_edit?(viewer_abac(socket), entry) do
          now = DateTime.utc_now() |> DateTime.to_iso8601()
          updated = %{entry | status: "rejected", updated_at: now}

          case Loader.save(updated) do
            :ok ->
              socket =
                socket
                |> put_flash(:info, "Spec '#{app}/#{id}' rejected ✗")
                |> assign(selected_spec: nil)
                |> load_data()

              {:noreply, socket}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Could not reject this document. Try again.")}
          end
        else
          {:noreply,
           put_flash(
             socket,
             :error,
             "Access denied: cannot edit specs at or above your clearance"
           )}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not load this document. Try again.")}
    end
  end

  @impl true
  def handle_event("deprecate-spec", %{"app" => app} = params, socket) do
    id = params["spec_id"] || params["id"]

    case Loader.load(app, id) do
      {:ok, entry} ->
        if Abac.can_edit?(viewer_abac(socket), entry) do
          deprecate_with_replacement(socket, entry, params["replacement_id"])
        else
          {:noreply,
           put_flash(
             socket,
             :error,
             "Access denied: cannot edit specs at or above your clearance"
           )}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not load this document. Try again.")}
    end
  end

  @impl true
  def handle_event("filter-status", %{"status" => status}, socket) do
    filter = if status == "", do: nil, else: status

    socket =
      assign(socket, status_filter: filter, selected_spec: nil, selected_spec_keys: MapSet.new())
      |> load_data()

    count = length(socket.assigns.specs)
    socket = put_flash(socket, :info, "Filter: #{filter || "all"} — #{count} specs")
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket =
      assign(socket, search_query: query, selected_spec: nil, selected_spec_keys: MapSet.new())
      |> load_data()

    {:noreply, socket}
  end

  def handle_event("toggle-select", %{"app" => app, "id" => id}, socket) do
    key = spec_key(app, id)
    selected = socket.assigns.selected_spec_keys

    selected =
      if MapSet.member?(selected, key),
        do: MapSet.delete(selected, key),
        else: MapSet.put(selected, key)

    {:noreply, assign(socket, selected_spec_keys: selected)}
  end

  def handle_event("clear-selection", _params, socket) do
    {:noreply, assign(socket, selected_spec_keys: MapSet.new())}
  end

  def handle_event("approve-selected", _params, socket) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    ctx = viewer_abac(socket)

    approved =
      socket.assigns.selected_spec_keys
      |> MapSet.to_list()
      |> Enum.map(&load_spec_key/1)
      |> Enum.filter(fn
        {:ok, entry} ->
          entry.status in ["proposed", "under_review"] and Abac.can_edit?(ctx, entry)

        _ ->
          false
      end)
      |> Enum.count(fn {:ok, entry} ->
        updated = %{entry | status: "approved", approved_by: "human", updated_at: now}
        Loader.save(%{updated | spec_hash: Entry.compute_spec_hash(updated)}) == :ok
      end)

    {:noreply,
     socket
     |> assign(selected_spec_keys: MapSet.new(), selected_spec: nil)
     |> put_flash(
       :info,
       "Approved #{approved} selected document#{if approved == 1, do: "", else: "s"}"
     )
     |> load_data()}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("approve-all-proposed", _, socket) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    ctx = viewer_abac(socket)

    case Loader.load_all() do
      {:ok, all_specs} ->
        proposed =
          all_specs
          |> Enum.filter(fn s -> s.status == "proposed" end)
          |> Enum.filter(&Abac.can_edit?(ctx, &1))

        results =
          Enum.map(proposed, fn entry ->
            updated = %{entry | status: "approved", approved_by: "human", updated_at: now}
            updated = %{updated | spec_hash: Entry.compute_spec_hash(updated)}

            case Loader.save(updated) do
              :ok -> {:ok, entry.id}
              {:error, reason} -> {:error, entry.id, reason}
            end
          end)

        approved = Enum.count(results, fn r -> match?({:ok, _}, r) end)
        failed = Enum.count(results, fn r -> match?({:error, _, _}, r) end)

        flash_msg =
          "Approved #{approved} specs" <> if failed > 0, do: " (#{failed} failed)", else: ""

        socket = socket |> put_flash(:info, flash_msg) |> load_data()
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not refresh documents. Try again.")}
    end
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp deprecate_with_replacement(socket, entry, replacement_id) do
    replacement =
      Enum.find(socket.assigns.replacement_candidates, fn candidate ->
        candidate.app <> "|" <> candidate.id == replacement_id
      end)

    case replacement do
      nil ->
        {:noreply, put_flash(socket, :error, "Choose an approved replacement first.")}

      replacement ->
        if Abac.can_edit?(viewer_abac(socket), replacement) do
          case Lineage.deprecate(entry, replacement) do
            {:ok, deprecated, replacement} ->
              case Loader.save(replacement) do
                :ok ->
                  case Loader.save(deprecated) do
                    :ok ->
                      {:noreply,
                       socket
                       |> put_flash(:info, "Document deprecated and linked to its replacement ⟳")
                       |> assign(selected_spec: nil)
                       |> load_data()}

                    {:error, _reason} ->
                      {:noreply,
                       put_flash(socket, :error, "Could not save the deprecated document.")}
                  end

                {:error, _reason} ->
                  {:noreply, put_flash(socket, :error, "Could not save the replacement link.")}
              end

            {:error, :entry_not_approved} ->
              {:noreply, put_flash(socket, :error, "Only approved documents can be deprecated.")}

            {:error, :replacement_not_approved} ->
              {:noreply, put_flash(socket, :error, "The replacement must be approved first.")}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Choose a different replacement document.")}
          end
        else
          {:noreply,
           put_flash(socket, :error, "Access denied: cannot edit the replacement document.")}
        end
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:specs_updated, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Same clearance rule as MCP: viewer's own authority level + role.
  defp viewer_abac(socket) do
    case socket.assigns[:current_user] do
      %{org_role: role, authority_level_slug: slug} ->
        Abac.from_keyword(
          agent_role: role,
          authority_level_slug: slug
        )

      %{org_role: role} ->
        Abac.from_keyword(agent_role: role)

      %{authority_level_slug: slug} ->
        Abac.from_keyword(authority_level_slug: slug)

      _ ->
        Abac.from_keyword([])
    end
  end

  defp load_data(socket) do
    search_query = socket.assigns.search_query
    ctx = viewer_abac(socket)

    all_specs =
      if search_query && search_query != "" do
        case Search.search(search_query) do
          {:ok, entries} -> Abac.filter(entries, ctx)
          _ -> []
        end
      else
        case Loader.load_all(app: nil) do
          {:ok, entries} ->
            entries
            |> Abac.filter(ctx)

          _ ->
            []
        end
      end

    specs = maybe_filter_by_status_in_view(all_specs, socket.assigns.status_filter)
    stats = compute_stats(all_specs)

    replacement_candidates =
      Enum.filter(all_specs, fn entry -> entry.status == "approved" end)

    selected_spec =
      if socket.assigns.selected_spec do
        Enum.find(specs, fn s ->
          s.app == socket.assigns.selected_spec.app && s.id == socket.assigns.selected_spec.id
        end)
      end

    assign(socket,
      specs: specs,
      stats: stats,
      selected_spec: selected_spec,
      replacement_candidates: replacement_candidates,
      loading: false
    )
  end

  defp maybe_filter_by_status_in_view(entries, nil), do: entries

  defp maybe_filter_by_status_in_view(entries, "proposed") do
    Enum.filter(entries, fn e -> e.status in ["proposed", "under_review"] end)
  end

  defp maybe_filter_by_status_in_view(entries, status) do
    Enum.filter(entries, fn e -> e.status == status end)
  end

  defp compute_stats(specs) do
    statuses =
      ~w(proposed under_review approved rejected deprecated contradicted runtime_divergent historical)

    base = Map.new(statuses, fn s -> {s, 0} end)

    stats =
      Enum.reduce(specs, Map.put(base, "total", length(specs)), fn entry, acc ->
        status = entry.status || "unknown"
        Map.update(acc, status, 1, &(&1 + 1))
      end)

    Map.update!(stats, "proposed", &(&1 + stats["under_review"]))
  end

  defp spec_key(app, id), do: app <> "\u0000" <> id

  defp load_spec_key(key) do
    case String.split(key, "\u0000", parts: 2) do
      [app, id] -> Loader.load(app, id)
      _ -> {:error, :invalid_key}
    end
  end

  defp selected_spec_count(specs, selected_keys) do
    Enum.count(specs, &MapSet.member?(selected_keys, spec_key(&1.app, &1.id)))
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

  # List-row snippet: purpose for module specs, content for documents.
  defp document_preview(%{purpose: purpose}) when is_binary(purpose) and purpose != "" do
    truncate_preview(purpose)
  end

  defp document_preview(%{content: content}) when is_binary(content) and content != "" do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_preview()
  end

  defp document_preview(_), do: nil

  defp truncate_preview(text) do
    if String.length(text) > 150, do: String.slice(text, 0, 150) <> "...", else: text
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="documents-governance">
      <section class="account-intro page-intro animate-in" aria-labelledby="documents-title">
        <p class="account-kicker" style="font-size: 0.5rem; margin-bottom: 6px;"><span>Knowledge</span> / Documents</p>
        <h1 id="documents-title" class="page-title">Documents</h1>
        <p class="page-description">Specifications, knowledge files, and shared artifacts for the workspace.</p>
      </section>

      <!-- Header with stats -->
      <div class="stats-grid">
        <.stat_card label="Total" value={@stats["total"]} status="" selected={is_nil(@status_filter)} />
        <.stat_card label="Proposed" value={@stats["proposed"]} status="proposed" color="var(--amber)" selected={@status_filter == "proposed"} />
        <.stat_card label="Approved" value={@stats["approved"]} status="approved" color="var(--green)" selected={@status_filter == "approved"} />
        <.stat_card label="Deprecated" value={@stats["deprecated"]} status="deprecated" color="var(--muted)" selected={@status_filter == "deprecated"} />
        <.stat_card label="Rejected" value={@stats["rejected"]} status="rejected" color="var(--red)" selected={@status_filter == "rejected"} />
      </div>

      <!-- Search -->
      <div class="page-search">
        <form phx-change="search">
          <input
            name="query"
            type="text"
            class="search-input"
            placeholder="Search documents by title, purpose, invariants..."
            aria-label="Search documents"
            value={@search_query}
          />
        </form>
      </div>

      <!-- Filters + Refresh -->
      <div class="page-toolbar">
        <div class="page-toolbar-actions">
          <%= if selected_spec_count(@specs, @selected_spec_keys) > 0 do %>
            <button phx-click="approve-selected" class="btn btn-primary compact-button">
              ✓ Approve selected (<%= selected_spec_count(@specs, @selected_spec_keys) %>)
            </button>
            <button phx-click="clear-selection" class="btn btn-ghost compact-button">Clear</button>
          <% end %>
          <button phx-click="refresh" class="btn btn-ghost compact-button">↻ Refresh</button>
          <%= if (@stats["proposed"] || 0) > 0 do %>
            <button phx-click="approve-all-proposed" class="btn btn-primary compact-button" title={"Approve all #{@stats["proposed"]} proposed documents"}>
              ✓ Approve All (<%= @stats["proposed"] %>)
            </button>
          <% end %>
        </div>
      </div>

      <!-- Document list -->
      <div class="governance-list">
        <%= if Enum.empty?(@specs) do %>
          <div class="card empty-card">
            <%= if assigns[:loading] == true do %>
              <div class="loading-state" role="status">Loading documents</div>
            <% else %>
              <div class="empty-state">
              <div class="empty-state-icon">◈</div>
              <p class="empty-state-title">
                <%= if @search_query != "" do %>
                  No documents match your search
                <% else %>
                  No documents found
                <% end %>
              </p>
              <p class="empty-state-desc">
                Use the document tools via agents or create documents manually.
              </p>
              </div>
            <% end %>
          </div>
        <% else %>
          <%= for entry <- @specs do %>
            <div
              phx-click="select-spec-detail"
              phx-keydown="select-spec-detail"
              phx-key="Enter"
              phx-value-app={entry.app}
              phx-value-id={entry.id}
              class={"tool-row #{if @selected_spec && @selected_spec.app == entry.app && @selected_spec.id == entry.id, do: "selected"}"}
              role="button"
              tabindex="0"
              aria-pressed={to_string(@selected_spec && @selected_spec.app == entry.app && @selected_spec.id == entry.id)}
              >
                <div style="display: flex; align-items: center; gap: 10px;">
                  <input class="selection-checkbox" type="checkbox" checked={MapSet.member?(@selected_spec_keys, spec_key(entry.app, entry.id))} phx-click="toggle-select" phx-value-app={entry.app} phx-value-id={entry.id} phx-stopPropagation aria-label={"Select #{entry.title || entry.id}"} />
                <span class={"status-dot status-#{entry.status || "unknown"}"}></span>
                <span class="category-badge"><%= entry.app %></span>
                <%= if entry.document_type do %>
                  <span class="category-badge"><%= entry.document_type %></span>
                <% end %>
                <span style="flex: 1; font-weight: 500; font-size: 0.88rem; color: var(--text);">
                  <%= entry.title || entry.id %>
                </span>
                <span style="font-size: 0.7rem; color: var(--muted); font-family: var(--font-mono);">
                  v<%= entry.version || "?" %>
                </span>
                <%= if entry.proposed_by do %>
                  <span style="font-size: 0.68rem; color: var(--muted);" title={"Proposed by #{entry.proposed_by}"}>
                    <%= entry.proposed_by %>
                  </span>
                <% end %>
                <%= if entry.audit_verdict do %>
                  <span style="font-size: 0.65rem; padding: 2px 6px; border-radius: 4px; background: var(--bg-elevated); color: var(--muted);" title={entry.audit_reasoning}>
                    audit: <%= entry.audit_verdict %><%= if entry.quality_score, do: " · #{entry.quality_score}" %>
                  </span>
                <% end %>
                <span style="font-size: 0.7rem; color: var(--muted);">
                  <%= entry.id %>
                </span>
                <%= if entry.verification_status do %>
                  <span style="font-size: 0.65rem; padding: 2px 6px; border-radius: 4px; background: var(--bg-elevated); color: var(--muted);">
                    <%= entry.verification_status %>
                  </span>
                <% end %>
              </div>
              <%= if preview = document_preview(entry) do %>
                <div style="font-size: 0.78rem; color: var(--text-dim); margin-top: 4px; margin-left: 22px;">
                  <%= preview %>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>

      <!-- Document popup -->
      <%= if @selected_spec do %>
        <div
          id="document-viewer"
          phx-window-keydown="deselect-spec"
          phx-key="Escape"
          role="dialog"
          aria-modal="true"
          aria-labelledby="document-modal-title"
          style="position: fixed; inset: 0; z-index: 10000; display: flex; align-items: center; justify-content: center; padding: 24px;"
        >
          <div
            phx-click="deselect-spec"
            aria-hidden="true"
            style="position: absolute; inset: 0; background: rgba(0, 0, 0, 0.72); backdrop-filter: blur(6px);"
          >
          </div>
          <div
            class="card"
            style="position: relative; z-index: 1; width: min(920px, 100%); max-height: calc(100vh - 48px); display: flex; flex-direction: column; padding: 0; overflow: hidden; box-shadow: 0 24px 80px rgba(0, 0, 0, 0.45);"
          >
            <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; padding: 20px 24px; border-bottom: 1px solid var(--border); background: var(--bg-elevated); flex-shrink: 0;">
              <div style="min-width: 0;">
                <div style="display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-bottom: 8px;">
                  <span class={"status-dot status-#{@selected_spec.status || "unknown"}"}></span>
                  <span class="category-badge"><%= @selected_spec.app %></span>
                  <%= if @selected_spec.document_type do %>
                    <span class="category-badge"><%= @selected_spec.document_type %></span>
                  <% end %>
                  <span style="font-size: 0.7rem; color: var(--muted); font-family: var(--font-mono);">v<%= @selected_spec.version || "?" %></span>
                </div>
                <h3 id="document-modal-title" style="font-size: 1.15rem; margin: 0 0 6px 0; color: var(--text); line-height: 1.3;">
                  <%= @selected_spec.title || @selected_spec.id %>
                </h3>
                <code style="font-size: 0.72rem; color: var(--muted);"><%= @selected_spec.app %>/<%= @selected_spec.id %></code>
              </div>
              <div style="display: flex; gap: 6px; align-items: center; flex-shrink: 0;">
                <%= if @selected_spec.status in ~w(proposed under_review) do %>
                  <button
                    phx-click="approve-spec"
                    phx-value-app={@selected_spec.app}
                    phx-value-id={@selected_spec.id}
                    class="btn btn-primary"
                    style="padding: 6px 14px; font-size: 0.72rem;"
                  >
                    ✓ Approve
                  </button>
                  <button
                    phx-click="reject-spec"
                    phx-value-app={@selected_spec.app}
                    phx-value-id={@selected_spec.id}
                    class="btn btn-danger"
                    style="padding: 6px 14px; font-size: 0.72rem;"
                  >
                    ✗ Reject
                  </button>
                <% end %>
                <%= if @selected_spec.status == "approved" do %>
                  <%= if Enum.any?(@replacement_candidates, &(&1.id != @selected_spec.id)) do %>
                    <form phx-submit="deprecate-spec" style="display: flex; gap: 6px; align-items: center;">
                      <input type="hidden" name="app" value={@selected_spec.app} />
                      <input type="hidden" name="spec_id" value={@selected_spec.id} />
                      <select name="replacement_id" required class="form-control form-control-sm" aria-label="Replacement document">
                        <option value="">Replacement…</option>
                        <%= for candidate <- @replacement_candidates, candidate.id != @selected_spec.id do %>
                          <option value={candidate.app <> "|" <> candidate.id}>
                            <%= candidate.title || candidate.id %>
                          </option>
                        <% end %>
                      </select>
                      <button type="submit" class="btn btn-ghost" style="padding: 6px 14px; font-size: 0.72rem;">
                        ⟳ Deprecate
                      </button>
                    </form>
                  <% else %>
                    <span class="table-muted" title="Approve a replacement document first">Approve a replacement first</span>
                  <% end %>
                <% end %>
                <button
                  phx-click="deselect-spec"
                  class="btn btn-ghost"
                  style="padding: 6px 10px; font-size: 0.72rem;"
                  title="Close (Esc)"
                  aria-label="Close document"
                >
                  ✕
                </button>
              </div>
            </div>

            <div style="overflow-y: auto; padding: 24px; flex: 1; min-height: 0;">
              <%= if is_binary(@selected_spec.content) and @selected_spec.content != "" do %>
                <div style="margin-bottom: 20px;">
                  <pre style="white-space: pre-wrap; word-break: break-word; margin: 0; padding: 18px; background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius); color: var(--text-dim); font-family: var(--font-mono); font-size: 0.8rem; line-height: 1.6;"><%= @selected_spec.content %></pre>
                </div>
              <% end %>

              <%= if @selected_spec.purpose do %>
                <div style="margin-bottom: 16px;">
                  <div class="agent-task-label">Purpose</div>
                  <div style="font-size: 0.85rem; color: var(--text-dim); line-height: 1.5; margin-top: 4px;"><%= @selected_spec.purpose %></div>
                </div>
              <% end %>

              <%= if @selected_spec.invariants && @selected_spec.invariants != [] do %>
                <div style="margin-bottom: 16px;">
                  <div class="agent-task-label">Invariants</div>
                  <ul style="margin-top: 6px; padding-left: 20px;">
                    <%= if is_list(@selected_spec.invariants) do %>
                      <%= for inv <- @selected_spec.invariants do %>
                        <%= if is_binary(inv) do %>
                          <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= inv %></li>
                        <% end %>
                      <% end %>
                    <% else %>
                      <%= if is_map(@selected_spec.invariants) do %>
                        <%= for {_k, v} <- @selected_spec.invariants do %>
                          <%= if is_binary(v) do %>
                            <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= v %></li>
                          <% end %>
                        <% end %>
                      <% end %>
                    <% end %>
                  </ul>
                </div>
              <% end %>

              <%= if @selected_spec.workflows && @selected_spec.workflows != [] do %>
                <div style="margin-bottom: 16px;">
                  <div class="agent-task-label">Workflows</div>
                  <ul style="margin-top: 6px; padding-left: 20px;">
                    <%= if is_list(@selected_spec.workflows) do %>
                      <%= for wf <- @selected_spec.workflows do %>
                        <%= if is_binary(wf) do %>
                          <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= wf %></li>
                        <% end %>
                      <% end %>
                    <% else %>
                      <%= if is_map(@selected_spec.workflows) do %>
                        <%= for {k, v} <- @selected_spec.workflows do %>
                          <%= if is_binary(v) do %>
                            <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= k %>: <%= v %></li>
                          <% else %>
                            <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= inspect(k) %></li>
                          <% end %>
                        <% end %>
                      <% end %>
                    <% end %>
                  </ul>
                </div>
              <% end %>

              <%= if @selected_spec.failure_modes && @selected_spec.failure_modes != [] do %>
                <div style="margin-bottom: 16px;">
                  <div class="agent-task-label">Failure Modes</div>
                  <ul style="margin-top: 6px; padding-left: 20px;">
                    <%= if is_list(@selected_spec.failure_modes) do %>
                      <%= for fm <- @selected_spec.failure_modes do %>
                        <%= if is_binary(fm) do %>
                          <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= fm %></li>
                        <% end %>
                      <% end %>
                    <% else %>
                      <%= if is_map(@selected_spec.failure_modes) do %>
                        <%= for {_k, v} <- @selected_spec.failure_modes do %>
                          <%= if is_binary(v) do %>
                            <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= v %></li>
                          <% end %>
                        <% end %>
                      <% end %>
                    <% end %>
                  </ul>
                </div>
              <% end %>

              <%= if @selected_spec.constraints && @selected_spec.constraints != [] do %>
                <div style="margin-bottom: 16px;">
                  <div class="agent-task-label">Constraints</div>
                  <ul style="margin-top: 6px; padding-left: 20px;">
                    <%= if is_list(@selected_spec.constraints) do %>
                      <%= for c <- @selected_spec.constraints do %>
                        <%= if is_binary(c) do %>
                          <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= c %></li>
                        <% end %>
                      <% end %>
                    <% else %>
                      <%= if is_map(@selected_spec.constraints) do %>
                        <%= for {_k, v} <- @selected_spec.constraints do %>
                          <%= if is_binary(v) do %>
                            <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= v %></li>
                          <% end %>
                        <% end %>
                      <% end %>
                    <% end %>
                  </ul>
                </div>
              <% end %>

              <%= if @selected_spec.tags && @selected_spec.tags != [] do %>
                <div style="margin-bottom: 16px;">
                  <div class="agent-task-label">Tags</div>
                  <div style="display: flex; gap: 6px; flex-wrap: wrap; margin-top: 6px;">
                    <%= if is_list(@selected_spec.tags) do %>
                      <%= for tag <- @selected_spec.tags do %>
                        <%= if is_binary(tag) do %>
                          <span style="padding: 2px 8px; background: var(--bg-elevated); border-radius: var(--radius-sm); font-size: 0.7rem; color: var(--muted);"><%= tag %></span>
                        <% end %>
                      <% end %>
                    <% else %>
                      <%= if is_map(@selected_spec.tags) do %>
                        <%= for {_k, v} <- @selected_spec.tags do %>
                          <%= if is_binary(v) do %>
                            <span style="padding: 2px 8px; background: var(--bg-elevated); border-radius: var(--radius-sm); font-size: 0.7rem; color: var(--muted);"><%= v %></span>
                          <% end %>
                        <% end %>
                      <% end %>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if @selected_spec.references && @selected_spec.references != [] do %>
                <div style="margin-bottom: 16px;">
                  <div class="agent-task-label">References</div>
                  <div style="margin-top: 6px;">
                    <%= for ref <- @selected_spec.references do %>
                      <div style="padding: 6px 10px; margin-bottom: 4px; background: var(--bg); border-radius: var(--radius-sm); font-size: 0.75rem;">
                        <span style="color: var(--text-dim);"><%= ref["type"] || "ref" %>:</span>
                        <code style="font-size: 0.72rem; color: var(--accent);"><%= ref["target"] %></code>
                        <%= if ref["description"] do %>
                          <span style="color: var(--muted);"> — <%= ref["description"] %></span>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <div style="border-top: 1px solid var(--border); padding-top: 12px; margin-top: 12px;">
                <div style="display: flex; gap: 16px; flex-wrap: wrap; font-size: 0.72rem; color: var(--muted);">
                  <span>Version: <strong><%= @selected_spec.version || "1" %></strong></span>
                  <%= if @selected_spec.parent_version && @selected_spec.parent_version > 0 do %>
                    <span>Parent: v<%= @selected_spec.parent_version %></span>
                  <% end %>
                  <%= if @selected_spec.proposed_by do %>
                    <span>Proposed by: <strong><%= @selected_spec.proposed_by %></strong></span>
                  <% end %>
                  <%= if @selected_spec.approved_by do %>
                    <span>Approved by: <strong><%= @selected_spec.approved_by %></strong></span>
                  <% end %>
                </div>
                <div style="display: flex; gap: 16px; flex-wrap: wrap; font-size: 0.72rem; color: var(--muted); margin-top: 6px;">
                  <span>Verification: <%= @selected_spec.verification_status || "unset" %></span>
                  <%= if @selected_spec.visibility do %>
                    <span>Visibility: <strong><%= @selected_spec.visibility %></strong></span>
                  <% end %>
                  <%= if @selected_spec.team do %>
                    <span>Team: <strong><%= @selected_spec.team %></strong></span>
                  <% end %>
                  <%= if @selected_spec.project do %>
                    <span>Project: <strong><%= @selected_spec.project %></strong></span>
                  <% end %>
                  <%= if @selected_spec.source do %>
                    <span>Source: <code style="font-size: 0.65rem;"><%= @selected_spec.source %></code></span>
                  <% end %>
                  <%= if @selected_spec.spec_hash do %>
                    <span title={@selected_spec.spec_hash}>
                      Hash: <code style="font-size: 0.65rem;"><%= String.slice(@selected_spec.spec_hash, 0, 12) %>…</code>
                    </span>
                  <% end %>
                </div>
                <%= if @selected_spec.audit_verdict || @selected_spec.quality_score || @selected_spec.audit_reasoning do %>
                  <div style="margin-top: 10px; padding: 10px 12px; background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius);">
                    <div style="font-family: var(--font-mono); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); margin-bottom: 6px;">LLM Audit</div>
                    <div style="display: flex; gap: 16px; flex-wrap: wrap; font-size: 0.72rem; color: var(--muted); margin-bottom: 4px;">
                      <%= if @selected_spec.audit_verdict do %>
                        <span>Verdict: <strong style="color: var(--text);"><%= @selected_spec.audit_verdict %></strong></span>
                      <% end %>
                      <%= if @selected_spec.quality_score do %>
                        <span>Quality: <strong style="color: var(--text);"><%= @selected_spec.quality_score %></strong></span>
                      <% end %>
                      <%= if @selected_spec.audited_at do %>
                        <span>Audited: <%= @selected_spec.audited_at %></span>
                      <% end %>
                    </div>
                    <%= if @selected_spec.audit_reasoning do %>
                      <div style="font-size: 0.78rem; color: var(--text-dim); line-height: 1.45;"><%= @selected_spec.audit_reasoning %></div>
                    <% end %>
                  </div>
                <% end %>
                <div style="display: flex; gap: 16px; margin-top: 6px; font-size: 0.72rem; color: var(--muted);">
                  <span>Created: <%= @selected_spec.created_at || "—" %></span>
                  <span>Updated: <%= @selected_spec.updated_at || "—" %></span>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end

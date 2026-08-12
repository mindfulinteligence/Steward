defmodule AcsWeb.AcsLive.PromptsLive do
  use AcsWeb, :live_view

  alias Acs.Org
  alias Acs.Prompts.Store

  @known_prompts [
    %{
      category: "memory",
      name: "intake",
      label: "Memory intake triage",
      desc:
        "Per-org LLM triage on save_memory (scope choice, quality questions, sensitive note). Heuristics apply when LLM is down."
    },
    %{
      category: "skills",
      name: "intake",
      label: "Skill intake triage",
      desc:
        "Per-org LLM triage on skill_save. Default allow; high bar for questions (secrets / unusable / no steps). Heuristics when LLM is down."
    },
    %{
      category: "memory",
      name: "evaluate",
      label: "Memory evaluation (coding)",
      desc: "Prompt for coding memory quality auditor"
    },
    %{
      category: "memory",
      name: "evaluate_chat",
      label: "Memory evaluation (chat)",
      desc: "Prompt for chat memory quality auditor"
    },
    %{
      category: "skills",
      name: "evaluate",
      label: "Skill evaluation (coding)",
      desc: "Prompt for coding skill quality auditor"
    },
    %{
      category: "skills",
      name: "evaluate_chat",
      label: "Skill evaluation (chat)",
      desc: "Prompt for chat skill quality auditor"
    },
    %{
      category: "skills",
      name: "instructions",
      label: "Skills instructions (coding)",
      desc: "Agent-facing instructions for how to use skills"
    },
    %{
      category: "skills",
      name: "instructions_chat",
      label: "Skills instructions (chat)",
      desc: "Chat-facing instructions for how to use skills"
    },
    %{
      category: "specs",
      name: "instructions",
      label: "Specs instructions (coding)",
      desc: "Agent-facing instructions for how to use specs/documents"
    },
    %{
      category: "specs",
      name: "instructions_chat",
      label: "Specs instructions (chat)",
      desc: "Chat-facing instructions for how to use specs/documents"
    }
  ]

  def on_mount(_params, _session, socket) do
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        selected_id: nil,
        selected: nil,
        editor_content: "",
        original_content: "",
        saving: false
      )

    {:ok, load_data(socket)}
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("select", %{"prompt_id" => id}, socket) do
    prompt = Enum.find(@known_prompts, &(prompt_id(&1) == id))

    if prompt do
      {content, source, override_exists} = current_content(prompt.category, prompt.name)

      socket =
        assign(socket,
          selected_id: id,
          selected: prompt,
          editor_content: content,
          original_content: content,
          source: source,
          override_exists: override_exists,
          saving: false
        )

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("editor-input", %{"content" => value}, socket) do
    {:noreply, assign(socket, editor_content: value)}
  end

  def handle_event("editor-input", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save", params, socket) do
    prompt = socket.assigns.selected
    content = Map.get(params, "content", socket.assigns.editor_content)

    case persist_override(prompt.category, prompt.name, content) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           editor_content: content,
           original_content: content,
           override_exists: true,
           source: :custom,
           saving: false
         )
         |> load_data()
         |> put_flash(:info, "Prompt saved successfully (#{prompt.category}/#{prompt.name}.md)")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to save prompt: #{format_file_error(reason)}")}
    end
  end

  @impl true
  def handle_event("revert", _params, socket) do
    prompt = socket.assigns.selected

    cond do
      not override_exists?(prompt.category, prompt.name) ->
        {:noreply, put_flash(socket, :error, "No custom override to revert")}

      true ->
        case remove_override(prompt.category, prompt.name) do
          :ok ->
            builtin = load_builtin(prompt.category, prompt.name)

            {:noreply,
             socket
             |> assign(
               editor_content: builtin,
               original_content: builtin,
               override_exists: false,
               source: :builtin
             )
             |> load_data()
             |> put_flash(:info, "Reverted to builtin prompt")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to revert prompt: #{format_file_error(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load_data(socket) do
    prompts =
      Enum.map(@known_prompts, fn p ->
        Map.put(p, :override_exists, override_exists?(p.category, p.name))
      end)

    assign(socket, prompts: prompts)
  end

  defp load_builtin(category, name) do
    path = Path.join([Application.app_dir(:steward_acs), "priv/prompts", category, "#{name}.md"])

    case File.read(path) do
      {:ok, content} -> String.trim(content)
      _ -> ""
    end
  end

  defp current_content(category, name) do
    builtin = load_builtin(category, name)

    if Org.multi_tenant?() do
      case Store.override(category, name) do
        {:ok, content} -> {content, :custom, true}
        :none -> {builtin, :builtin, false}
      end
    else
      case override_path(category, name) do
        nil ->
          {builtin, :builtin, false}

        file_path ->
          if File.regular?(file_path) do
            {:ok, bin} = File.read(file_path)
            {String.trim(bin), :custom, true}
          else
            {builtin, :builtin, false}
          end
      end
    end
  end

  defp override_exists?(category, name) do
    if Org.multi_tenant?() do
      Store.override_exists?(category, name)
    else
      case override_path(category, name) do
        nil -> false
        file_path -> File.regular?(file_path)
      end
    end
  end

  defp persist_override(category, name, content) do
    if Org.multi_tenant?() do
      Store.save_override(category, name, content)
    else
      case override_dir(category) do
        nil ->
          {:error, :no_vault_dir}

        dir ->
          with :ok <- File.mkdir_p(dir),
               :ok <- File.write(Path.join(dir, "#{name}.md"), content),
               do: {:ok, nil}
      end
    end
  end

  defp remove_override(category, name) do
    if Org.multi_tenant?() do
      case Store.tombstone(category, name) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      case override_path(category, name) do
        nil -> {:error, :enoent}
        file_path -> File.rm(file_path)
      end
    end
  end

  defp override_path(category, name) do
    case override_dir(category) do
      nil -> nil
      dir -> Path.join(dir, "#{name}.md")
    end
  end

  defp override_dir(category) do
    if Org.multi_tenant?() do
      nil
    else
      case Org.prompts_dir() do
        nil -> nil
        dir -> Path.join(dir, category)
      end
    end
  end

  defp prompt_id(prompt), do: "#{prompt.category}/#{prompt.name}"

  defp format_file_error(:eacces), do: "permission denied writing to the vault"
  defp format_file_error(:enoent), do: "vault path does not exist"
  defp format_file_error(:enospc), do: "no space left on device"
  defp format_file_error(:erofs), do: "vault filesystem is read-only"
  defp format_file_error(:no_vault_dir), do: "no vault prompts directory configured for this org"
  defp format_file_error({:ledger_write_failed, reason}), do: to_string(reason)
  defp format_file_error(reason), do: inspect(reason)

  defp source_badge(:custom), do: "Custom override"
  defp source_badge(:builtin), do: "Builtin"

  defp template_vars(%{category: "memory", name: "intake"}),
    do: [
      {"candidate_json",
       "proposed memory fields as JSON (kind, title, content, about_*, visibility, …)"}
    ]

  defp template_vars(%{category: "skills", name: "intake"}),
    do: [
      {"candidate_json",
       "proposed skill fields as JSON (name, description, when_to_use, content, tags, scope_paths)"}
    ]

  defp template_vars(%{category: "memory", name: name})
       when name in ["evaluate", "evaluate_chat"],
       do: [
         {"memory_json", "memory entry as JSON"},
         {"existing_memories_json", "context memories as JSON"}
       ]

  defp template_vars(%{category: "skills", name: name})
       when name in ["evaluate", "evaluate_chat"],
       do: [
         {"skill_json", "skill entry as JSON"},
         {"existing_skills_json", "context skills as JSON"}
       ]

  defp template_vars(_), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <section id="prompts-live" class="account-shell">
      <div class="account-intro animate-in">
        <p class="account-kicker" style="font-size: 0.5rem; margin-bottom: 6px;"><span>Workspace</span> / Prompts</p>
        <h1 style="font-size: 1.3rem; margin-bottom: 6px;">Prompt editor</h1>
        <p style="font-size: 0.82rem;">
          <%= if Org.multi_tenant?() do %>
            Edit per-org prompt overrides (memory intake, auditors, instructions). Overrides are
            stored per-org in the immutable artifact ledger and take effect on the next load;
            builtin defaults remain until you save.
          <% else %>
            Edit org prompts (memory intake, auditors, instructions). Overrides go to your vault
            <code>prompts/</code> and take effect on the next load; builtin defaults remain until you save.
          <% end %>
        </p>
      </div>

      <div class="card animate-in delay-1" style="padding: 24px;">
        <div class="prompts-picker">
          <label for="prompt-select" class="form-label">Select prompt</label>
          <div class="prompts-picker-row">
            <form phx-change="select">
              <select id="prompt-select" name="prompt_id" class="form-control form-select" style="max-width: 420px;">
                <option value="">Choose a prompt to edit…</option>
                <%= for p <- @prompts do %>
                  <option value={prompt_id(p)} selected={@selected_id == prompt_id(p)}>
                    <%= "#{p.label}" %>
                    <%= if p.override_exists do %>
                      <%= "(custom)" %>
                    <% end %>
                  </option>
                <% end %>
              </select>
            </form>
            <button type="button" phx-click="refresh" class="btn btn-ghost btn-sm" title="Refresh prompt list">
              ↻
            </button>
          </div>
        </div>

        <%= if @selected do %>
          <div class="prompts-editor-section">
            <form id="prompt-editor-form" phx-change="editor-input" phx-submit="save">
              <div class="prompts-editor-header">
                <div>
                  <div class="prompts-path">
                    <code><%= @selected.category %>/<%= @selected.name %>.md</code>
                    <span class={"source-tag #{@source}"}><%= source_badge(@source) %></span>
                  </div>
                  <p class="text-dim" style="font-size: 0.78rem; margin-top: 4px;"><%= @selected.desc %></p>
                </div>
                <div class="prompts-actions">
                  <button
                    type="button"
                    phx-click="revert"
                    class="btn btn-ghost btn-sm"
                    disabled={not @override_exists}
                    data-confirm="Revert to the builtin prompt? Your custom override will be deleted."
                  >
                    Revert
                  </button>
                  <button
                    type="submit"
                    class="btn btn-primary btn-sm"
                    disabled={@saving or @editor_content == @original_content}
                  >
                    <%= if @saving, do: "Saving…", else: "Save override" %>
                  </button>
                </div>
              </div>

              <div class="prompts-editor-body">
                <textarea
                  id={"prompt-editor-#{@selected_id}"}
                  name="content"
                  class="form-control prompt-textarea"
                  phx-debounce="300"
                  spellcheck="false"
                ><%= @editor_content %></textarea>
              </div>

              <details class="prompts-refs">
                <summary class="prompts-refs-summary">Template variables</summary>
                <div class="prompts-refs-body">
                  <%= for {var, hint} <- template_vars(@selected) do %>
                    <code><%= "{{#{var}}}" %></code> — <%= hint %><br>
                  <% end %>
                  <%= if template_vars(@selected) == [] do %>
                    No template variables — this prompt is used as-is.
                  <% end %>
                </div>
              </details>
            </form>
          </div>
        <% else %>
          <div class="empty-state" style="margin-top: 12px;">
            <div class="empty-state-icon" aria-hidden="true">◇</div>
            <p class="empty-state-title">Select a prompt</p>
            <p class="empty-state-desc">Choose a prompt from the dropdown to inspect or edit it.</p>
          </div>
        <% end %>
      </div>
    </section>
    """
  end
end

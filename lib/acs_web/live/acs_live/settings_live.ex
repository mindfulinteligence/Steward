defmodule AcsWeb.AcsLive.SettingsLive do
  @moduledoc """
  Tenant LiveView for organization settings and administrative actions.
  """

  use AcsWeb, :live_view
  alias Acs
  alias Acs.Developers

  def on_mount(_params, _session, socket) do
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns[:current_user]
    role = Map.get(current_user || %{}, :org_role)

    socket =
      socket
      |> assign(
        is_admin: role in ["owner", "admin"],
        local_identity?: not Acs.Org.multi_tenant?(),
        developer_name: Acs.Org.usable_developer_name() || "",
        name_form: to_form(%{"name" => Acs.Org.usable_developer_name() || ""}, as: :identity),
        key_form:
          to_form(%{"name" => Acs.Org.usable_developer_name() || "", "kind" => "code"}, as: :key),
        minted_key: nil,
        developers: list_dev_keys()
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("reset-all", _, socket) do
    if socket.assigns.is_admin do
      Acs.reset_all()

      {:noreply,
       socket
       |> put_flash(:info, "All Steward task, lock, and agent data has been reset.")}
    else
      {:noreply,
       put_flash(socket, :error, "Only organization administrators can reset workspace data.")}
    end
  end

  def handle_event("save-developer-name", %{"identity" => %{"name" => name}}, socket) do
    if socket.assigns.local_identity? and socket.assigns.is_admin do
      case Acs.Org.set_developer_name(name) do
        {:ok, trimmed} ->
          socket =
            case socket.assigns.current_user do
              %Acs.Accounts.User{} = user ->
                case Acs.Accounts.update_user_name(user, trimmed) do
                  {:ok, updated_user} ->
                    assign(socket,
                      developer_name: trimmed,
                      name_form: to_form(%{"name" => trimmed}, as: :identity),
                      current_user: updated_user
                    )

                  _ ->
                    assign(socket,
                      developer_name: trimmed,
                      name_form: to_form(%{"name" => trimmed}, as: :identity)
                    )
                end

              _ ->
                assign(socket,
                  developer_name: trimmed,
                  name_form: to_form(%{"name" => trimmed}, as: :identity)
                )
            end

          {:noreply,
           put_flash(
             socket,
             :info,
             "Coding identity set to #{trimmed}. Your account name is updated. Restart Cursor MCP (or reconnect) to pick it up."
           )}

        {:error, :blank} ->
          {:noreply, put_flash(socket, :error, "Enter your name.")}

        {:error, :placeholder} ->
          {:noreply, put_flash(socket, :error, "Pick a real name — not \"unknown\".")}

        {:error, :multi_tenant} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Use a developer API key for identity on multi-tenant hosts."
           )}
      end
    else
      {:noreply, put_flash(socket, :error, "Only local admins can set the coding identity.")}
    end
  end

  def handle_event("mint-developer-key", %{"key" => %{"name" => name, "kind" => kind}}, socket) do
    if socket.assigns.is_admin do
      name = String.trim(name || "")
      kind = if kind in ["code", "chat"], do: kind, else: "code"

      if name == "" do
        {:noreply, put_flash(socket, :error, "Name is required for a developer key.")}
      else
        case Developers.generate_key(name, role: "admin", org: Acs.Org.current(), kind: kind) do
          {:ok, %{key: raw_key, developer: dev}} ->
            _ = if socket.assigns.local_identity?, do: Acs.Org.set_developer_name(name)

            {:noreply,
             socket
             |> assign(
               minted_key: raw_key,
               developers: list_dev_keys(),
               developer_name: Acs.Org.usable_developer_name() || name,
               key_form: to_form(%{"name" => name, "kind" => kind}, as: :key),
               name_form: to_form(%{"name" => name}, as: :identity)
             )
             |> put_flash(
               :info,
               "#{kind} key created for #{dev.developer_name}. Copy it now — it will not be shown again. Put it in your MCP client as x-api-key (prod #{kind} path)."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not create key: #{inspect(reason)}")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "Only organization administrators can mint keys.")}
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp list_dev_keys do
    Developers.list_developers()
    |> Enum.filter(& &1.active)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="settings-shell">
      <section class="account-intro animate-in" aria-labelledby="settings-title">
        <p class="account-kicker" style="font-size: 0.5rem; margin-bottom: 6px;"><span>Workspace</span> / Configuration</p>
        <h1 id="settings-title" style="font-size: 1.3rem; margin-bottom: 6px;">Settings</h1>
        <p style="font-size: 0.82rem;">Manage workspace data and organization configuration.</p>
      </section>

      <%= if @is_admin do %>
        <div class="card" style="padding: 24px; margin-bottom: 16px;">
          <div class="section-header" style="align-items: flex-start; margin-bottom: 12px;">
            <div>
              <h2 class="section-title">Developer name</h2>
              <p class="text-dim" style="font-size: 0.8rem; margin-top: 5px;">
                Your named coding identity for MCP.
                <%= if @local_identity? do %>
                  Local shared <code>MCP_API_KEY</code> uses this name in Active Agents.
                  You can also set it with <code>ACS_DEVELOPER_NAME</code> in your <code>.env</code>.
                <% else %>
                  Use a developer API key for identity on multi-tenant hosts.
                <% end %>
              </p>
            </div>
          </div>

          <%= if @local_identity? do %>
            <.form for={@name_form} id="developer-name-form" phx-submit="save-developer-name">
              <label for="identity-name" class="form-label">Your name</label>
              <div style="display: flex; gap: 8px; align-items: center; margin-top: 6px;">
                <input
                  id="identity-name"
                  type="text"
                  name={@name_form[:name].name}
                  value={@name_form[:name].value}
                  class="form-input"
                  placeholder="e.g. Nahar"
                  autocomplete="name"
                  style="flex: 1;"
                />
                <button type="submit" class="btn btn-primary">Save name</button>
              </div>
            </.form>
          <% end %>
        </div>

        <div class="card" style="padding: 24px; margin-bottom: 16px;">
          <div class="section-header" style="align-items: flex-start; margin-bottom: 12px;">
            <div>
              <h2 class="section-title">Developer API keys</h2>
              <p class="text-dim" style="font-size: 0.8rem; margin-top: 5px;">
                Prod coding path: mint an <code>acs_dev_</code> key and put it in your agent’s
                <code>x-api-key</code> header (e.g. Cursor <code>mcp.json</code>).
              </p>
            </div>
          </div>

          <.form for={@key_form} id="mint-key-form" phx-submit="mint-developer-key">
            <label for="key-name" class="form-label">Name on the key</label>
            <div style="display: flex; gap: 8px; align-items: center; margin-top: 6px;">
              <input
                id="key-name"
                type="text"
                name={@key_form[:name].name}
                value={@key_form[:name].value}
                class="form-input"
                placeholder="e.g. Nahar"
                style="flex: 1;"
              />
              <button type="submit" class="btn btn-copy">Generate key</button>
            </div>

            <div style="display: flex; gap: 16px; margin-top: 12px;">
              <label style="display: flex; gap: 6px; align-items: center; font-size: 0.8rem;">
                <input
                  type="radio"
                  name={@key_form[:kind].name}
                  value="code"
                  checked={@key_form[:kind].value == "code"}
                />
                Code
              </label>
              <label style="display: flex; gap: 6px; align-items: center; font-size: 0.8rem;">
                <input
                  type="radio"
                  name={@key_form[:kind].name}
                  value="chat"
                  checked={@key_form[:kind].value == "chat"}
                />
                Chat
              </label>
            </div>
          </.form>

          <%= if @minted_key do %>
            <div style="margin-top: 14px;">
              <p class="text-dim" style="font-size: 0.75rem; margin-bottom: 6px;">Copy now — shown once:</p>
              <div class="mcp-url-row">
                <code id="minted-acs-dev-key" class="mcp-url-value"><%= @minted_key %></code>
                <button
                  type="button"
                  class="btn btn-copy"
                  data-copy-value={@minted_key}
                  data-copy-label="Copy key"
                  data-copy-success="Copied."
                >
                  Copy key
                </button>
              </div>
            </div>
          <% end %>

          <%= if @developers != [] do %>
            <ul class="text-dim" style="font-size: 0.8rem; margin-top: 16px; list-style: none; padding: 0;">
              <%= for dev <- @developers do %>
                <li style="padding: 4px 0;">
                  <strong style="color: var(--text);"><%= dev.developer_name %></strong>
                  · <%= dev.role %> · <%= dev.kind || "code" %> · <code><%= dev.key_prefix %>…</code>
                </li>
              <% end %>
            </ul>
          <% end %>
        </div>

        <div class="card" style="padding: 24px;">
          <div class="section-header" style="align-items: flex-start;">
            <div>
              <h2 class="section-title">Workspace data</h2>
              <p class="text-dim" style="font-size: 0.8rem; margin-top: 5px;">Administrative recovery actions. Resetting removes every task, file lock, and agent status in this workspace.</p>
            </div>
            <button
              phx-click="reset-all"
              data-confirm="Permanently delete all tasks, file locks, and agent statuses in this workspace? This cannot be undone."
              class="btn btn-danger"
              style="margin-left: auto;"
            >
              Reset workspace data
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end

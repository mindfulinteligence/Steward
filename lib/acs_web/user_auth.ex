defmodule AcsWeb.UserAuth do
  use AcsWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.Controller

  alias Acs.Accounts
  alias Acs.Orgs

  @session_key :user_token
  @known_accounts_cookie "_acs_known_accounts"
  @known_accounts_max 8

  def log_in_user(conn, user, opts \\ []) do
    redirect_to = Keyword.get(opts, :redirect_to, "/")

    conn
    |> put_user_session(user)
    |> remember_known_account(user)
    |> redirect(to: internal_path(redirect_to))
  end

  def put_user_session(conn, user) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> renew_session()
    |> put_session(@session_key, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end

  def log_out_user(conn) do
    user_token = get_session(conn, @session_key)

    case user_token && Accounts.get_user_by_session_token(user_token) do
      %{id: user_id} -> Accounts.revoke_user_auth(user_id)
      _ -> user_token && Accounts.delete_user_session_token(user_token)
    end

    if live_socket_id = get_session(conn, :live_socket_id) do
      AcsWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(external: account_url(conn, "/"))
  end

  def fetch_current_user(conn, _opts) do
    user_token = get_session(conn, @session_key)

    conn
    |> assign(:current_user, user_token && Accounts.get_user_by_session_token(user_token))
    |> assign(:known_accounts, known_accounts(conn))
  end

  @doc """
  Orgs/emails previously signed into on this browser, newest first, each with
  a ready-to-navigate `"url"` and whether it's the org for the current host.
  Backed by a long-lived cookie shared across tenant subdomains, so the
  switcher survives across sessions without any server-side account model.
  """
  def known_accounts(conn) do
    if Acs.Org.multi_tenant?() do
      conn = fetch_cookies(conn)
      current_org = conn.assigns[:current_org]

      conn.cookies
      |> Map.get(@known_accounts_cookie)
      |> decode_known_accounts()
      |> Enum.sort_by(& &1["at"], :desc)
      |> Enum.map(fn entry ->
        entry
        |> Map.put("url", tenant_url(conn, entry["org"], "/") || "")
        |> Map.put("current", entry["org"] == current_org)
      end)
      |> Enum.reject(&(&1["url"] == ""))
    else
      []
    end
  end

  def redirect_if_authenticated(conn, _opts) do
    case conn.assigns[:current_user] do
      nil -> conn
      user -> redirect_authenticated_user(conn, user)
    end
  end

  def require_authenticated_user(conn, _opts) do
    cond do
      conn.assigns[:current_user] ->
        conn

      account_landing_request?(conn) ->
        conn
        |> AcsWeb.AccountLandingController.render_landing()
        |> halt()

      account_host?(conn) ->
        conn
        |> maybe_store_return_to()
        |> redirect(to: "/")
        |> halt()

      true ->
        login_url =
          if conn.method == "GET" do
            account_url(conn, "/auth/log_in", %{return_to: current_path(conn)})
          else
            account_url(conn, "/auth/log_in")
          end

        conn
        |> maybe_store_return_to()
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(external: login_url)
        |> halt()
    end
  end

  def require_account_host(conn, _opts) do
    if conn.assigns[:host_type] in [:account, :account_tenant] do
      conn
    else
      conn
      |> redirect(external: account_url(conn, current_path(conn)))
      |> halt()
    end
  end

  def require_tenant_user(conn, _opts) do
    if tenant_user?(conn.assigns[:current_user], conn.assigns[:current_org]) do
      :ok = Acs.Org.put_current(conn.assigns.current_org)
      conn
    else
      case {conn.assigns[:host_type], conn.assigns[:current_user]} do
        {host, user} when host in [:account, :account_tenant] and is_map(user) ->
          redirect_authenticated_user(conn, user)

        _ ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(404, "not found")
          |> halt()
      end
    end
  end

  def require_org_admin(conn, _opts) do
    if tenant_user?(conn.assigns[:current_user], conn.assigns[:current_org]) and
         organization_role(conn.assigns.current_user) in ["owner", "admin"] do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "forbidden")
      |> halt()
    end
  end

  def fetch_user_token(conn) do
    %{
      "user_token" => get_session(conn, @session_key),
      "current_org" => conn.assigns[:current_org],
      "host_type" => Atom.to_string(conn.assigns[:host_type] || :unknown),
      "known_accounts" => conn.assigns[:known_accounts] || []
    }
  end

  def on_mount(:assign_known_accounts, _params, session, socket) do
    {:cont, Phoenix.Component.assign(socket, :known_accounts, session["known_accounts"] || [])}
  end

  def on_mount(:assign_org, _params, session, socket) do
    case session["current_org"] do
      org when is_binary(org) and org != "" ->
        :ok = Acs.Org.put_current(org)

        organization =
          case socket.assigns[:current_user] do
            %{organization: %_struct{slug: ^org} = preloaded} ->
              preloaded

            _ ->
              Orgs.get_by_slug(org)
          end

        socket = Phoenix.Component.assign(socket, :current_org, org)
        {:cont, Phoenix.Component.assign(socket, :organization, organization)}

      _ ->
        {:cont, socket}
    end
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket =
      assign_new(socket, :current_user, fn ->
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end
      end)

    if socket.assigns.current_user do
      {:cont, subscribe_to_user_disconnect(socket, socket.assigns.current_user)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/auth/log_in")}
    end
  end

  def on_mount(:ensure_account_host, _params, session, socket) do
    if session["host_type"] in ["account", "account_tenant"] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  def on_mount(:ensure_tenant_member, _params, session, socket) do
    org = session["current_org"] || socket.assigns[:current_org]
    user = socket.assigns[:current_user]

    if tenant_user?(user, org, socket.assigns[:organization]) do
      :ok = Acs.Org.put_current(org)
      {:cont, Phoenix.Component.assign(socket, :current_org, org)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/auth/log_in")}
    end
  end

  def on_mount(:ensure_org_admin, _params, session, socket) do
    org = session["current_org"] || socket.assigns[:current_org]
    user = socket.assigns[:current_user]

    if tenant_user?(user, org, socket.assigns[:organization]) and
         organization_role(user) in ["owner", "admin"] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket =
      assign_new(socket, :current_user, fn ->
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end
      end)

    if socket.assigns.current_user do
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    else
      {:cont, socket}
    end
  end

  def account_url(conn, path, query \\ %{}) do
    absolute_url(conn, account_host(), path, query)
  end

  def tenant_url(conn, org, path, query \\ %{}) do
    if Acs.Org.multi_tenant?() do
      with label when is_binary(label) <- tenant_label(org),
           true <- Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, label),
           base when is_binary(base) <- tenant_base_domain(),
           true <- valid_host?(base) do
        absolute_url(conn, label <> "." <> base, path, query)
      else
        _ -> nil
      end
    else
      absolute_url(conn, account_host(), path, query)
    end
  end

  def account_path(path), do: internal_path(path)

  def valid_return_to?(path) when is_binary(path) do
    uri = URI.parse(path)

    String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
      is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.userinfo) and
      not String.contains?(path, ["\\", "\r", "\n"])
  end

  def valid_return_to?(_), do: false

  def organization_for_user(user), do: Accounts.organization_for_user(user)

  def organization_ready?(org) when is_map(org) do
    case Map.get(org, :id) || Map.get(org, "id") do
      id when is_integer(id) ->
        (Map.get(org, :provisioning_status) || Map.get(org, "provisioning_status")) == "ready"

      _ ->
        true
    end
  end

  def organization_ready?(_), do: false

  defp redirect_authenticated_user(conn, user) do
    case conn.assigns[:host_type] do
      :tenant ->
        conn
        |> redirect(to: "/")
        |> halt()

      :account_tenant ->
        if tenant_user?(user, conn.assigns[:current_org]) do
          conn
          |> redirect(to: "/")
          |> halt()
        else
          redirect_account_user(conn, user)
        end

      :account ->
        redirect_account_user(conn, user)

      _ ->
        conn
        |> redirect(to: "/")
        |> halt()
    end
  end

  defp redirect_account_user(conn, user) do
    case organization_for_user(user) do
      org when is_map(org) ->
        cond do
          not organization_ready?(org) ->
            conn
            |> redirect(to: "/onboarding")
            |> halt()

          # ponytail: single-tenant has no subdomain boundary; skip handoff.
          not Acs.Org.multi_tenant?() ->
            conn
            |> redirect(to: "/")
            |> halt()

          true ->
            redirect_with_handoff(conn, user, org)
        end

      _ ->
        conn
        |> redirect(to: "/onboarding")
        |> halt()
    end
  end

  defp redirect_with_handoff(conn, user, org) do
    if organization_ready?(org) do
      return_to = stored_return_to(conn)

      case Accounts.create_session_handoff(user, org, return_to) do
        {:ok, token} when is_binary(token) ->
          case tenant_url(conn, org, "/auth/handoff", %{token: token}) do
            url when is_binary(url) ->
              conn
              |> delete_session(:user_return_to)
              |> put_resp_header("referrer-policy", "no-referrer")
              |> redirect(external: url)
              |> halt()

            _ ->
              conn
              |> redirect(to: "/onboarding")
              |> halt()
          end

        _ ->
          conn
          |> redirect(to: "/onboarding")
          |> halt()
      end
    else
      conn
      |> redirect(to: "/onboarding")
      |> halt()
    end
  end

  defp account_landing_request?(conn) do
    conn.method == "GET" and conn.request_path == "/" and account_host?(conn)
  end

  defp account_host?(conn) do
    conn.assigns[:host_type] in [:account, :account_tenant]
  end

  defp tenant_user?(user, slug, preloaded_org \\ nil)

  defp tenant_user?(user, slug, preloaded_org) when is_map(user) and is_binary(slug) do
    organization = preloaded_org || organization_for_user(user)

    with ^slug <- Map.get(organization, :slug) || Map.get(organization, "slug"),
         true <- organization_ready?(organization) do
      true
    else
      _ -> false
    end
  end

  defp tenant_user?(_, _, _), do: false

  defp organization_role(user) when is_map(user) do
    Map.get(user, :org_role) || Map.get(user, "org_role") || Map.get(user, :role) ||
      Map.get(user, "role")
  end

  defp organization_role(_), do: nil

  defp subscribe_to_user_disconnect(socket, %{id: user_id}) do
    topic = "users:#{user_id}"

    if Phoenix.LiveView.connected?(socket) do
      AcsWeb.Endpoint.subscribe(topic)
    end

    Phoenix.LiveView.attach_hook(socket, :user_disconnect, :handle_info, fn
      %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, socket ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/users/log_in")}

      _message, socket ->
        {:cont, socket}
    end)
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp stored_return_to(conn) do
    case get_session(conn, :user_return_to) do
      path when is_binary(path) -> internal_path(path)
      _ -> "/"
    end
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp internal_path(path) when is_binary(path) do
    if valid_return_to?(path), do: path, else: "/"
  end

  defp internal_path(_), do: "/"

  defp account_host do
    case Application.get_env(:steward_acs, :account_host, "localhost") do
      host when is_binary(host) ->
        if valid_host?(host), do: String.downcase(host), else: "localhost"

      _ ->
        "localhost"
    end
  end

  defp tenant_label(org) when is_map(org) do
    Map.get(org, :subdomain) || Map.get(org, "subdomain") || Map.get(org, :slug) ||
      Map.get(org, "slug")
  end

  defp tenant_label(slug) when is_binary(slug), do: slug
  defp tenant_label(_), do: nil

  defp tenant_base_domain do
    Application.get_env(:steward_acs, :base_domain) || account_host()
  end

  defp absolute_url(conn, host, path, query) do
    endpoint_url = Application.get_env(:steward_acs, AcsWeb.Endpoint, []) |> Keyword.get(:url, [])
    scheme = Keyword.get(endpoint_url, :scheme) || to_string(conn.scheme || :http)
    port = Keyword.get(endpoint_url, :port) || conn.port

    %URI{
      scheme: to_string(scheme),
      host: host,
      port: normalize_port(port, scheme),
      path: internal_path(path),
      query: if(query == %{}, do: nil, else: URI.encode_query(query))
    }
    |> URI.to_string()
  end

  defp normalize_port(port, scheme) when scheme in ["https", :https] and port == 443, do: nil
  defp normalize_port(port, scheme) when scheme in ["http", :http] and port == 80, do: nil
  defp normalize_port(port, _scheme), do: port

  defp valid_host?(host) do
    Regex.match?(~r/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/, String.downcase(host))
  end

  defp remember_known_account(conn, user) do
    org = conn.assigns[:current_org]
    email = Map.get(user, :email) || Map.get(user, "email")

    if Acs.Org.multi_tenant?() and is_binary(org) and org != "" and is_binary(email) and
         email != "" do
      put_known_accounts_cookie(conn, org, email)
    else
      conn
    end
  end

  defp put_known_accounts_cookie(conn, org, email) do
    conn = fetch_cookies(conn)

    entries =
      conn.cookies
      |> Map.get(@known_accounts_cookie)
      |> decode_known_accounts()
      |> Enum.reject(&same_account?(&1, org, email))

    org_name =
      case Orgs.get_by_slug(org) do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> org
      end

    entry = %{
      "org" => org,
      "name" => org_name,
      "email" => email,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    entries = [entry | entries] |> Enum.take(@known_accounts_max)

    put_resp_cookie(
      conn,
      @known_accounts_cookie,
      Jason.encode!(entries),
      known_accounts_cookie_opts()
    )
  end

  defp known_accounts_cookie_opts do
    [
      # 180 days — outlives any single login session; this cookie only ever
      # holds {org, email, timestamp} hints, never a credential, so a long
      # lifetime and cross-subdomain domain (below) carry no auth risk.
      max_age: 60 * 60 * 24 * 180,
      http_only: true,
      secure: Application.get_env(:steward_acs, :secure_session_cookie, false),
      same_site: "Lax",
      path: "/"
    ]
    |> maybe_put_shared_domain()
  end

  defp maybe_put_shared_domain(opts) do
    case Application.get_env(:steward_acs, :base_domain) do
      base when is_binary(base) and base != "" and base != "localhost" ->
        Keyword.put(opts, :domain, "." <> base)

      _ ->
        opts
    end
  end

  defp decode_known_accounts(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) -> Enum.filter(list, &valid_account_entry?/1)
      _ -> []
    end
  end

  defp decode_known_accounts(_), do: []

  defp valid_account_entry?(%{"org" => org, "email" => email})
       when is_binary(org) and org != "" and is_binary(email) and email != "",
       do: true

  defp valid_account_entry?(_), do: false

  defp same_account?(%{"org" => org, "email" => email}, org, target_email) do
    String.downcase(email) == String.downcase(target_email)
  end

  defp same_account?(_, _, _), do: false
end

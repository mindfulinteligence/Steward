defmodule AcsWeb.UserAuthTest do
  use AcsWeb.ConnCase, async: false

  alias Acs.Accounts
  alias Acs.Orgs.Organization
  alias AcsWeb.UserAuth

  setup do
    Acs.Org.clear_request_org()
    :ok
  end

  describe "require_tenant_user/2" do
    test "allows a member of the ready tenant organization" do
      organization = organization!()
      user = member!(organization, "member")

      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_org, organization.slug)

      result = UserAuth.require_tenant_user(conn, [])

      refute result.halted
      assert Acs.Org.current() == organization.slug
    end

    test "returns not found when the user belongs to a different tenant" do
      organization = organization!()
      other_organization = organization!()
      user = member!(organization, "member")

      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_org, other_organization.slug)

      assert %Plug.Conn{halted: true, status: 404, resp_body: "not found"} =
               UserAuth.require_tenant_user(conn, [])
    end
  end

  describe "require_org_admin/2" do
    test "allows an organization admin on their tenant" do
      organization = organization!()
      admin = member!(organization, "admin")

      conn =
        Plug.Test.conn(:get, "/settings/members")
        |> Plug.Conn.assign(:current_user, admin)
        |> Plug.Conn.assign(:current_org, organization.slug)

      result = UserAuth.require_org_admin(conn, [])

      refute result.halted
    end

    test "returns forbidden for a tenant member without an admin role" do
      organization = organization!()
      member = member!(organization, "member")

      conn =
        Plug.Test.conn(:get, "/settings/members")
        |> Plug.Conn.assign(:current_user, member)
        |> Plug.Conn.assign(:current_org, organization.slug)

      assert %Plug.Conn{halted: true, status: 403, resp_body: "forbidden"} =
               UserAuth.require_org_admin(conn, [])
    end
  end

  describe "known account switcher" do
    setup do
      previous =
        for key <- [:base_domain, :account_host, :multi_tenant, :basic_auth, :org_name],
            into: %{},
            do: {key, Application.get_env(:steward_acs, key)}

      Application.put_env(:steward_acs, :base_domain, "example.test")
      Application.put_env(:steward_acs, :account_host, "acme.example.test")
      Application.put_env(:steward_acs, :multi_tenant, true)
      Application.put_env(:steward_acs, :basic_auth, username: "admin", password: "secret")
      Application.put_env(:steward_acs, :org_name, "acme")

      on_exit(fn ->
        Enum.each(previous, fn
          {key, nil} -> Application.delete_env(:steward_acs, key)
          {key, value} -> Application.put_env(:steward_acs, key, value)
        end)
      end)

      acme = organization!("acme")
      beta = organization!("beta")

      %{acme: acme, beta: beta}
    end

    defp on_host(conn, host), do: Map.put(conn, :host, host)

    test "logging in on a tenant host remembers the org and email for the switcher", %{
      conn: conn,
      acme: acme,
      beta: beta
    } do
      conn =
        conn
        |> on_host("acme.example.test")
        |> post("/users/log_in", %{"user" => %{"username" => "admin", "password" => "secret"}})

      assert redirected_to(conn) == "/"
      [set_cookie] = get_resp_header(conn, "set-cookie") |> Enum.filter(&(&1 =~ "_acs_known_accounts"))
      assert set_cookie =~ "domain=.example.test"

      known =
        conn
        |> recycle()
        |> on_host("beta.example.test")
        |> Plug.Conn.assign(:current_org, beta.slug)
        |> UserAuth.known_accounts()

      assert [%{"org" => "acme", "email" => "admin@localhost", "current" => false} = entry] =
               known

      assert entry["url"] == "http://acme.example.test/"
      assert entry["name"] == acme.name

      current =
        conn
        |> recycle()
        |> on_host("acme.example.test")
        |> Plug.Conn.assign(:current_org, acme.slug)
        |> UserAuth.known_accounts()

      assert [%{"current" => true}] = current
    end
  end

  defp member!(organization, role) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "#{role}-#{System.unique_integer([:positive])}@example.test",
        org: organization.slug,
        organization_id: organization.id,
        org_role: role
      })

    user
  end

  defp organization! do
    suffix = System.unique_integer([:positive])
    organization!("tenant-#{suffix}")
  end

  defp organization!(slug) do
    Repo.insert!(
      Organization.changeset(%Organization{}, %{
        name: String.capitalize(slug),
        slug: slug,
        subdomain: slug,
        provisioning_status: "ready"
      })
    )
  end
end

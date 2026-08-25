defmodule AcsWeb.Plugs.ResolveOrgTest do
  use AcsWeb.ConnCase, async: false

  alias AcsWeb.Plugs.ResolveOrg

  setup do
    original_env =
      Map.new([:account_host, :base_domain, :multi_tenant, :orgs_file], fn key ->
        {key, Application.fetch_env(:steward_acs, key)}
      end)

    orgs_file =
      Path.join(
        System.tmp_dir!(),
        "resolve_org_test_#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(
      orgs_file,
      """
      orgs:
        yaml-tenant:
          name: YAML Tenant
          slug: yaml-tenant
          subdomain: yaml-tenant
          plan: free
      """
    )

    Application.put_env(:steward_acs, :account_host, "account.stewardacs.xyz")
    Application.put_env(:steward_acs, :base_domain, "stewardacs.xyz")
    Application.put_env(:steward_acs, :multi_tenant, true)
    Application.put_env(:steward_acs, :orgs_file, orgs_file)
    Acs.Org.clear_request_org()

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, {:ok, value}} -> Application.put_env(:steward_acs, key, value)
        {key, :error} -> Application.delete_env(:steward_acs, key)
      end)

      Acs.Org.clear_request_org()
      File.rm(orgs_file)
    end)

    :ok
  end

  test "identifies the configured account host" do
    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "account.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert result.assigns.host_type == :account
    refute Map.has_key?(result.assigns, :current_org)
  end

  test "account host that is also an org subdomain keeps account_tenant scope" do
    Application.put_env(:steward_acs, :account_host, "yaml-tenant.stewardacs.xyz")

    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "yaml-tenant.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert result.assigns.host_type == :account_tenant
    assert result.assigns.current_org == "yaml-tenant"
    assert Acs.Org.current() == "yaml-tenant"
  end

  test "assigns the tenant for a known YAML organization host" do
    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "yaml-tenant.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert result.assigns.host_type == :tenant
    assert result.assigns.current_org == "yaml-tenant"
    assert Acs.Org.current() == "yaml-tenant"
  end

  test "available subdomain shows claim landing instead of plain 404" do
    Application.put_env(:steward_acs, :self_service_orgs_enabled, true)

    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "acme.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert result.halted
    assert result.status == 200
    assert result.assigns.host_type == :available
    assert result.assigns.available_subdomain == "acme"
    body = result.resp_body
    assert body =~ "acme is available"
    assert body =~ "Create your organization"
    assert body =~ "return_to="
  end

  test "scanner vanity hosts stay plain 404" do
    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "partner.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert %Plug.Conn{halted: true, status: 404, resp_body: "unknown org"} = result
    assert result.assigns.host_type == :unknown
  end

  test "MCP paths on unknown hosts stay plain 404" do
    result =
      Plug.Test.conn(:get, "/mcp/sse")
      |> Map.put(:host, "acme.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert %Plug.Conn{halted: true, status: 404, resp_body: "unknown org"} = result
  end

  test "allows /mcp/health on localhost without a tenant host" do
    result =
      Plug.Test.conn(:get, "/mcp/health")
      |> Map.put(:host, "localhost")
      |> ResolveOrg.call([])

    refute result.halted
    assert result.assigns.host_type == :account_tenant
  end

  test "resets the pool and retries a stale tenant lookup once" do
    test_pid = self()

    lookup = fn ->
      case Process.get(:org_lookup_attempt, 0) do
        0 ->
          Process.put(:org_lookup_attempt, 1)
          raise DBConnection.ConnectionError, message: "ssl send: closed"

        1 ->
          :found
      end
    end

    assert :found =
             ResolveOrg.retry_org_lookup(lookup, fn interval ->
               send(test_pid, {:disconnected, interval})
               :ok
             end)

    assert_received {:disconnected, 0}
  end
end

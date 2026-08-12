defmodule Acs.MCP.Plugs.Strategies.DeveloperTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Plugs.Strategies.Developer
  alias Acs.Developers

  # Build a minimal mock conn — the strategy doesn't inspect conn fields
  defp build_conn do
    %Plug.Conn{
      remote_ip: {127, 0, 0, 1},
      req_headers: [],
      query_params: %{},
      assigns: %{}
    }
  end

  describe "authenticate/2" do
    test "authenticates with valid developer key" do
      {:ok, %{key: raw_key}} =
        Developers.generate_key("strategy-test", role: "admin", cluster: "dev")

      conn = build_conn()
      # Developer strategy maps cluster to org_id
      assert {:ok, %{role: "admin", org_id: "dev", kind: "code"}} =
               Developer.authenticate(raw_key, conn)
    end

    test "returns chat kind for chat keys" do
      {:ok, %{key: raw_key}} =
        Developers.generate_key("strategy-chat-test", role: "admin", cluster: "dev", kind: "chat")

      conn = build_conn()
      assert {:ok, %{kind: "chat"}} = Developer.authenticate(raw_key, conn)
    end

    test "rejects invalid key" do
      conn = build_conn()
      assert {:error, _} = Developer.authenticate("acs_dev_invalid_key_that_is_long_enough", conn)
    end

    test "rejects non-developer key" do
      conn = build_conn()
      assert {:error, "Not a developer key"} = Developer.authenticate("some-other-key", conn)
    end

    test "handles nil key" do
      conn = build_conn()
      assert {:error, "Not a developer key"} = Developer.authenticate(nil, conn)
    end
  end
end

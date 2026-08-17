defmodule Acs.Auth0.OrgAudienceTest do
  use ExUnit.Case, async: true

  alias Acs.Auth0.OrgAudience

  test "audience_for builds per-tenant MCP resource URL" do
    assert OrgAudience.audience_for("anantha", "stewardacs.xyz") ==
             "https://anantha.stewardacs.xyz/mcp/sse"
  end

  test "broker_wildcard_callback_url builds wildcard broker callback for the fixed DCR client" do
    assert OrgAudience.broker_wildcard_callback_url("stewardacs.xyz") ==
             "https://*.stewardacs.xyz/oauth/callback"
  end

  test "ensure_async is a no-op when Management API is not configured" do
    assert :ok = OrgAudience.ensure_async("anantha")
  end
end

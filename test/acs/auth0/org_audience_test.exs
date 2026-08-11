defmodule Acs.Auth0.OrgAudienceTest do
  use ExUnit.Case, async: true

  alias Acs.Auth0.OrgAudience

  test "audience_for builds per-tenant MCP resource URL" do
    assert OrgAudience.audience_for("anantha", "stewardacs.xyz") ==
             "https://anantha.stewardacs.xyz/mcp/sse"
  end

  test "broker_callback_url builds per-tenant broker callback for the fixed DCR client" do
    assert OrgAudience.broker_callback_url("safetyconnect", "stewardacs.xyz") ==
             "https://safetyconnect.stewardacs.xyz/oauth/callback"
  end

  test "ensure_async is a no-op when Management API is not configured" do
    assert :ok = OrgAudience.ensure_async("anantha")
  end
end

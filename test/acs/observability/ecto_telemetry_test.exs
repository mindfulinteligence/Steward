defmodule Acs.Observability.EctoTelemetryTest do
  use ExUnit.Case, async: true

  test "Repo emits the telemetry prefix registered by Acs.Application" do
    assert Acs.Repo.config()[:telemetry_prefix] == [:steward_acs, :repo]
  end
end

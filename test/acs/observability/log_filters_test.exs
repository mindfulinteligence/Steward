defmodule Acs.Observability.LogFiltersTest do
  use ExUnit.Case, async: true

  alias Acs.Observability.LogFilters

  defp event(msg, mod \\ DBConnection.Connection),
    do: %{level: :error, msg: msg, meta: %{mfa: {mod, :disconnect, 2}}}

  test "stops stale-socket disconnects from DBConnection" do
    text =
      "Postgrex.Protocol (#PID<0.1.0>) disconnected: ** (DBConnection.ConnectionError) ssl send: closed"

    assert :stop = LogFilters.neon_idle_disconnect(event({:string, text}), [])

    assert :stop =
             LogFilters.neon_idle_disconnect(
               event({~c"~s disconnected: ssl recv (idle): closed", ["conn"]}),
               []
             )
  end

  test "keeps other DBConnection errors and other modules" do
    assert :ignore =
             LogFilters.neon_idle_disconnect(event({:string, "connection refused"}), [])

    assert :ignore =
             LogFilters.neon_idle_disconnect(event({:string, "ssl send: closed"}, MyApp), [])
  end
end

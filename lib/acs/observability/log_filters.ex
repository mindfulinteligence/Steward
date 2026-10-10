defmodule Acs.Observability.LogFilters do
  @moduledoc """
  Logger primary filters.

  `neon_idle_disconnect/2` drops the one routine message DBConnection logs at
  error level when Neon autosuspends: the idle compute closes every pooled
  socket, Postgrex does not watch idle sockets, and the next use of each fails
  with `ssl send: closed` / `ssl recv (idle): closed`. DBConnection reconnects
  on its own and the affected query is either retried by its caller or fails
  visibly in that caller's own log, so the pool-level line is ~1,400 error
  entries/week of noise. Every other DBConnection error is left alone.
  """

  @stale_markers ["ssl send: closed", "ssl recv (idle): closed", "tcp send: closed"]

  @spec neon_idle_disconnect(:logger.log_event(), term()) :: :logger.filter_return()
  def neon_idle_disconnect(%{meta: %{mfa: {DBConnection.Connection, _, _}}, msg: msg}, _extra) do
    if stale_socket?(msg), do: :stop, else: :ignore
  end

  def neon_idle_disconnect(_event, _extra), do: :ignore

  defp stale_socket?(msg) do
    text =
      case msg do
        {:string, chardata} ->
          IO.chardata_to_string(chardata)

        {format, args} when is_list(args) ->
          format |> :io_lib.format(args) |> IO.chardata_to_string()

        _ ->
          ""
      end

    Enum.any?(@stale_markers, &String.contains?(text, &1))
  rescue
    _ -> false
  end
end

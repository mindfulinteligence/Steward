defmodule Acs.Observability.CacheOps do
  @moduledoc """
  Structured cache hit/miss telemetry for Axiom export.

  Emits info-level events tagged `action: "cache_access"` so the steward_logs
  dataset can compute hit rates and miss-driven refill counts per cache. Kept
  as its own module so every cache layer (FileCache, Acs.Acs.Cache, HealthCache,
  JWKS) emits one consistent event shape.
  """

  require Logger

  @doc """
  Build the structured metadata for a cache access event.

  Returns the keyword list handed to Logger, carrying `action`,
  `cache_name`, and `cache_result` plus optional `cache_type`, `count`,
  `org`, and `latency_ms`. Keys with nil/empty values are dropped so the
  AxiomLogBackend allowlist stays sparse.
  """
  def event(opts) do
    [
      action: "cache_access",
      cache_name: to_string(Keyword.fetch!(opts, :cache_name)),
      cache_result: to_string(Keyword.fetch!(opts, :result)),
      cache_type: Keyword.get(opts, :type) |> to_label(),
      count: Keyword.get(opts, :count),
      latency_ms: Keyword.get(opts, :latency_ms),
      org: Keyword.get(opts, :org)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  @doc "Emit an info-level cache access event."
  def log(opts) do
    meta = event(opts)
    Logger.info("[Cache] #{meta[:cache_name]} #{meta[:cache_result]}", meta)
    :ok
  end

  defp to_label(nil), do: nil
  defp to_label(value) when is_binary(value), do: value
  defp to_label(value) when is_atom(value), do: Atom.to_string(value)

  defp to_label(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map_join(":", &to_label/1)
  end

  defp to_label(value), do: inspect(value)
end

defmodule Acs.LLM.Router do
  @moduledoc """
  Resolves, at call time, the ordered provider priority list and optional
  model override for a given (region, call_type).

  Priority is resolved highest-first:

    1. `LLM_PRIORITY_<REGION>_<CALLTYPE>`  (env, exact region+call type)
    2. `LLM_PRIORITY_<CALLTYPE>`            (env, any region)
    3. `LLM_PRIORITY_<REGION>`              (env, any call type)
    4. code fallback map (region -> call types)
    5. default `["tokenrouter","nim","minimax","openai"]`

  Model override precedence (highest-first):

    1. `LLM_MODEL_<REGION>_<CALLTYPE>`  (env)
    2. `LLM_MODEL_<CALLTYPE>`            (env)
    3. base model (per-provider override or the provider's `default_model`)

  Env vars are read at call time via `System.get_env`, so tests can set them
  with `System.put_env` and deploys can override without a code change. The
  region comes from Application config `:acs_region` (set in `runtime.exs`
  from the `ACS_REGION` env var, default `"default"`).
  """

  @default_priority ["tokenrouter", "nim", "minimax", "openai"]

  @fallback_priorities %{
    "default" => %{"default" => @default_priority},
    "sg" => %{"default" => ["tokenrouter", "openai"], "intake" => ["openai"]},
    "us" => %{"default" => ["openai"], "intake" => ["openai"]}
  }

  @spec region() :: String.t()
  def region do
    case Application.get_env(:steward_acs, :acs_region) do
      nil -> System.get_env("ACS_REGION", "default")
      "" -> "default"
      value when is_binary(value) -> value
    end
  end

  @doc "Ordered provider list for a (region, call_type), env-overridable."
  @spec priority_for(String.t(), String.t()) :: [String.t()]
  def priority_for(region, call_type) do
    region = normalize(region, "default")
    call_type = normalize(call_type, "")

    first_non_empty([
      env_list("LLM_PRIORITY", region, call_type),
      env_list("LLM_PRIORITY", nil, call_type),
      env_list("LLM_PRIORITY", region, nil),
      code_priority(region, call_type),
      @default_priority
    ])
  end

  @doc "Model override for a (region, provider, call_type); falls back to base_model."
  @spec model_for(String.t(), String.t(), String.t(), String.t() | nil) :: String.t() | nil
  def model_for(region, _provider_id, call_type, base_model) do
    region = normalize(region, "default")
    call_type = normalize(call_type, "")

    env_value("LLM_MODEL", region, call_type) ||
      env_value("LLM_MODEL", nil, call_type) ||
      base_model
  end

  defp env_list(prefix, region, call_type) do
    prefix
    |> env_var(region, call_type)
    |> System.get_env()
    |> parse_list()
  end

  defp env_value(prefix, region, call_type) do
    case prefix |> env_var(region, call_type) |> System.get_env() do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp env_var(prefix, nil, nil), do: prefix
  defp env_var(prefix, region, nil), do: "#{prefix}_#{String.upcase(region)}"
  defp env_var(prefix, nil, call_type), do: "#{prefix}_#{String.upcase(call_type)}"

  defp env_var(prefix, region, call_type),
    do: "#{prefix}_#{String.upcase(region)}_#{String.upcase(call_type)}"

  defp parse_list(nil), do: []
  defp parse_list(""), do: []

  defp parse_list(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp code_priority(region, call_type) do
    map = Map.get(@fallback_priorities, region, %{})
    Map.get(map, call_type) || Map.get(map, "default") || []
  end

  defp first_non_empty([head | rest]) do
    case head do
      list when is_list(list) and list != [] -> list
      _ -> first_non_empty(rest)
    end
  end

  defp first_non_empty([]), do: @default_priority

  defp normalize(value, fallback) do
    value = value || fallback
    if is_binary(value), do: String.downcase(value), else: fallback
  end
end

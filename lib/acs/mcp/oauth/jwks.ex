defmodule Acs.MCP.OAuth.JWKS do
  @moduledoc false

  alias Acs.MCP.OAuth.Config
  alias Acs.Observability.CacheOps

  @cache_key {:acs_mcp_jwks, :keys}
  @cache_ttl_ms 3_600_000

  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def verify(token, opts \\ []) do
    if is_binary(token) do
      expected_audience = Keyword.get(opts, :audience)

      with {:ok, header} <- decode_header(token),
           :ok <- validate_algorithm(header),
           kid when is_binary(kid) <- header["kid"],
           {:ok, jwk} <- fetch_jwk(kid),
           {:ok, claims} <- verify_signature(token, jwk),
           :ok <- validate_claims(claims, expected_audience) do
        {:ok, claims}
      else
        nil -> {:error, "JWT missing key id"}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "Invalid bearer token"}
    end
  end

  defp decode_header(token) do
    case String.split(token, ".", parts: 3) do
      [header_b64, _payload, _sig] ->
        with {:ok, json} <- Base.url_decode64(header_b64, padding: false),
             {:ok, header} <- Jason.decode(json) do
          {:ok, header}
        else
          _ -> {:error, "Invalid JWT header"}
        end

      _ ->
        {:error, "Malformed JWT"}
    end
  end

  defp validate_algorithm(%{"alg" => "RS256"}), do: :ok
  defp validate_algorithm(_), do: {:error, "Unsupported JWT signing algorithm"}

  defp verify_signature(token, jwk) do
    case JOSE.JWT.verify(jwk, token) do
      {true, %JOSE.JWT{fields: claims}, _} ->
        {:ok, claims}

      _ ->
        {:error, "Invalid JWT signature"}
    end
  end

  defp validate_claims(claims, expected_audience) when is_map(claims) do
    now = System.system_time(:second)

    with :ok <- validate_issuer(claims),
         :ok <- validate_audience(claims, expected_audience),
         :ok <- validate_expiry(claims, now) do
      :ok
    end
  end

  defp validate_issuer(%{"iss" => iss}) when is_binary(iss) do
    expected = Config.issuer()

    if iss == expected or iss == expected <> "/" do
      :ok
    else
      {:error, "Invalid token issuer"}
    end
  end

  defp validate_issuer(_), do: {:error, "JWT missing issuer"}

  defp validate_audience(%{"aud" => aud}, expected) when is_binary(aud) do
    if aud in accepted_audiences(expected), do: :ok, else: {:error, "Invalid token audience"}
  end

  defp validate_audience(%{"aud" => aud}, expected) when is_list(aud) do
    if Enum.any?(aud, &(&1 in accepted_audiences(expected))),
      do: :ok,
      else: {:error, "Invalid token audience"}
  end

  defp validate_audience(_, _), do: {:error, "JWT missing audience"}

  defp accepted_audiences(expected) when is_binary(expected) and expected != "" do
    Config.accepted_resource_urls(expected)
  end

  defp accepted_audiences(_), do: Config.accepted_resource_urls(Config.audience())

  defp validate_expiry(%{"exp" => exp}, now) when is_integer(exp) do
    if exp > now, do: :ok, else: {:error, "JWT expired"}
  end

  defp validate_expiry(_, _), do: {:error, "JWT missing expiry"}

  defp fetch_jwk(kid) do
    case cached_keys()[kid] do
      %JOSE.JWK{} = jwk ->
        {:ok, jwk}

      _ ->
        refresh_keys()

        case cached_keys()[kid] do
          %JOSE.JWK{} = jwk -> {:ok, jwk}
          _ -> {:error, "Unknown signing key"}
        end
    end
  end

  defp cached_keys do
    case :persistent_term.get(@cache_key, :missing) do
      {keys, fetched_at} when is_map(keys) ->
        if System.monotonic_time(:millisecond) - fetched_at < @cache_ttl_ms do
          CacheOps.log(cache_name: "jwks", result: "hit")
          keys
        else
          CacheOps.log(cache_name: "jwks", result: "expired")
          refresh_keys()
        end

      :missing ->
        CacheOps.log(cache_name: "jwks", result: "miss")
        refresh_keys()
    end
  end

  defp refresh_keys do
    keys =
      case fetch_jwks_json() do
        {:ok, %{"keys" => jwks}} when is_list(jwks) ->
          Map.new(jwks, fn jwk_map ->
            jwk = JOSE.JWK.from_map(jwk_map)
            {jwk_map["kid"], jwk}
          end)

        _ ->
          %{}
      end

    :persistent_term.put(@cache_key, {keys, System.monotonic_time(:millisecond)})
    keys
  end

  defp fetch_jwks_json do
    case Config.jwks_url() do
      nil ->
        {:error, :missing_jwks_url}

      url ->
        case Req.get(url) do
          {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
          {:ok, %{status: 200, body: body}} when is_binary(body) -> Jason.decode(body)
          _ -> {:error, :jwks_fetch_failed}
        end
    end
  end
end

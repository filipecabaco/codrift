defmodule Codrift.Integration.HTTP do
  @moduledoc """
  Thin HTTP/S client for external integration API calls.

  Uses OTP's built-in `:httpc` — no extra runtime dependencies.
  Starts `:inets` and `:ssl` on first use; safe to call repeatedly.

  All responses with status 2xx are decoded as JSON (falling back to raw
  binary when the body is not valid JSON). Non-2xx responses return
  `{:error, "HTTP {status}: {body}"}`.
  """

  @timeout_ms 15_000

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  @doc "HTTP GET, returns `{:ok, decoded_json}` or `{:error, reason}`."
  @spec get(String.t(), [{String.t(), String.t()}]) :: {:ok, term()} | {:error, term()}
  def get(url, headers \\ []) do
    request(:get, url, headers, nil, nil)
  end

  @doc "HTTP POST with JSON body, returns `{:ok, decoded_json}` or `{:error, reason}`."
  @spec post(String.t(), term(), [{String.t(), String.t()}]) :: {:ok, term()} | {:error, term()}
  def post(url, body, headers \\ []) do
    request(:post, url, headers, "application/json", JSON.encode!(body))
  end

  @doc "GraphQL query over HTTP POST."
  @spec graphql(String.t(), String.t(), map(), [{String.t(), String.t()}]) ::
          {:ok, term()} | {:error, term()}
  def graphql(url, query, variables \\ %{}, headers \\ []) do
    post(url, %{query: query, variables: variables}, headers)
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp request(method, url, headers, content_type, body) do
    ensure_started()

    char_url = String.to_charlist(url)
    char_headers = Enum.map(headers, fn {k, v} -> {as_charlist(k), as_charlist(v)} end)
    http_opts = [ssl: ssl_opts(), timeout: @timeout_ms, connect_timeout: @timeout_ms]
    inet_opts = [body_format: :binary]

    result =
      if method == :get do
        :httpc.request(:get, {char_url, char_headers}, http_opts, inet_opts)
      else
        :httpc.request(
          method,
          {char_url, char_headers, as_charlist(content_type), body},
          http_opts,
          inet_opts
        )
      end

    handle_response(result)
  end

  defp handle_response({:ok, {{_, status, _}, _headers, body}}) when status in 200..299 do
    case JSON.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:ok, body}
    end
  end

  defp handle_response({:ok, {{_, status, _}, _headers, body}}) do
    {:error, "HTTP #{status}: #{body}"}
  end

  defp handle_response({:error, reason}) do
    {:error, inspect(reason)}
  end

  defp ensure_started do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
  end

  defp as_charlist(s) when is_binary(s), do: String.to_charlist(s)
  defp as_charlist(s) when is_list(s), do: s
end

defmodule Codrift.Integration.HTTP do
  @moduledoc """
  Thin HTTP/S client for external integration API calls.

  All responses with status 2xx are decoded as JSON (falling back to raw
  binary when the body is not valid JSON). Non-2xx responses return
  `{:error, "HTTP {status}: {body}"}`.
  """

  @timeout_ms 15_000

  @doc "HTTP GET, returns `{:ok, decoded_json}` or `{:error, reason}`."
  @spec get(String.t(), [{String.t(), String.t()}]) :: {:ok, term()} | {:error, term()}
  def get(url, headers \\ []) do
    request(:get, url, headers, nil)
  end

  @doc "HTTP POST with JSON body, returns `{:ok, decoded_json}` or `{:error, reason}`."
  @spec post(String.t(), term(), [{String.t(), String.t()}]) :: {:ok, term()} | {:error, term()}
  def post(url, body, headers \\ []) do
    request(:post, url, headers, body)
  end

  @doc """
  HTTP POST with an `application/x-www-form-urlencoded` body.

  OAuth 2.0 token endpoints and the device authorization endpoint require form
  encoding — RFC 6749 §4.1.3 and RFC 8628 §3.1 both specify it, and providers
  enforce it: Linear rejects a JSON body with
  `invalid_request: content must be application/x-www-form-urlencoded`.
  Use this for OAuth; use `post/3` for ordinary JSON APIs.
  """
  @spec post_form(String.t(), map(), [{String.t(), String.t()}]) ::
          {:ok, term()} | {:error, term()}
  def post_form(url, params, headers \\ []) do
    request(:post, url, headers, {:form, params})
  end

  @doc "GraphQL query over HTTP POST."
  @spec graphql(String.t(), String.t(), map(), [{String.t(), String.t()}]) ::
          {:ok, term()} | {:error, term()}
  def graphql(url, query, variables \\ %{}, headers \\ []) do
    post(url, %{query: query, variables: variables}, headers)
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp request(method, url, headers, body) do
    opts = [
      headers: headers,
      receive_timeout: @timeout_ms,
      connect_options: [timeout: @timeout_ms]
    ]

    opts =
      case body do
        nil -> opts
        {:form, params} -> Keyword.put(opts, :form, params)
        json -> Keyword.put(opts, :json, json)
      end

    result =
      case method do
        :get -> Req.get(url, opts)
        :post -> Req.post(url, opts)
      end

    handle_response(result)
  end

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    decoded =
      case body do
        b when is_binary(b) ->
          case JSON.decode(b) do
            {:ok, data} -> data
            {:error, _} -> b
          end

        other ->
          other
      end

    {:ok, decoded}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, "HTTP #{status}: #{inspect(body)}"}
  end

  defp handle_response({:error, reason}) do
    {:error, inspect(reason)}
  end
end

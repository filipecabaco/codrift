defmodule Codrift.Integration.HTTP do
  @moduledoc """
  Thin HTTP/S client for external integration API calls.

  All responses with status 2xx are decoded as JSON (falling back to raw
  binary when the body is not valid JSON). Non-2xx responses return
  `{:error, %Codrift.Integration.Error{}}` — see `explain/2` for why the body
  is mined for a sentence instead of being inspected.
  """

  alias Codrift.Integration.Error

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

  # A failed call used to surface as `inspect(body)`, which put a raw Elixir map
  # — `%{"errors" => [%{"extensions" => ...` — in front of the user in the
  # initiative picker. Providers already write a human sentence into these
  # bodies; the job here is to find it and to say, via `:kind`, whether the user
  # can do anything about it.
  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, Error.new(kind_for(status), explain(status, body), status: status)}
  end

  # Req's error channel is always an exception struct (connection refused, TLS
  # failure, timeout), and `Exception.message/1` is what turns those into the
  # sentence the user sees — `inspect/1` on the same value produces a tuple.
  defp handle_response({:error, exception}) do
    {:error, Error.new(:network, Exception.message(exception))}
  end

  defp kind_for(401), do: :auth
  defp kind_for(403), do: :forbidden
  defp kind_for(404), do: :not_found
  defp kind_for(429), do: :rate_limited
  defp kind_for(_), do: :http

  @doc """
  Turns a failed response body into one sentence a person can read.

  Every provider Codrift talks to buries a usable message somewhere different —
  Linear in `errors[].extensions.userPresentableMessage`, GitHub in `message`,
  OAuth endpoints in `error_description` — so the shapes are tried in order of
  how specific they are and the status line is the last resort. Public because
  the mapping is worth testing directly.
  """
  @spec explain(pos_integer(), term()) :: String.t()
  def explain(status, body) do
    case message_in(decode(body)) do
      nil -> "HTTP #{status}"
      message -> "#{message} (HTTP #{status})"
    end
  end

  defp decode(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, data} -> data
      {:error, _} -> body
    end
  end

  defp decode(body), do: body

  # GraphQL errors first: Linear and GitHub Projects both answer this way, and
  # `userPresentableMessage` is the provider's own wording for an end user.
  defp message_in(%{"errors" => [_ | _] = errors}) do
    errors
    |> Enum.map(&graphql_message/1)
    |> Enum.reject(&is_nil/1)
    |> join()
  end

  defp message_in(%{"error_description" => description}) when is_binary(description),
    do: presence(description)

  defp message_in(%{"message" => message}) when is_binary(message), do: presence(message)
  defp message_in(%{"error" => error}) when is_binary(error), do: presence(error)

  defp message_in(%{"error" => %{"message" => message}}) when is_binary(message),
    do: presence(message)

  # An HTML error page or a stack trace is not a message; truncate hard rather
  # than paste a wall of markup into a one-line UI slot.
  defp message_in(body) when is_binary(body), do: body |> String.slice(0, 200) |> presence()
  defp message_in(_), do: nil

  defp graphql_message(%{"extensions" => %{"userPresentableMessage" => message}})
       when is_binary(message),
       do: presence(message)

  defp graphql_message(%{"message" => message}) when is_binary(message), do: presence(message)
  defp graphql_message(_), do: nil

  defp join([]), do: nil
  defp join(messages), do: messages |> Enum.uniq() |> Enum.join("; ")

  defp presence(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end

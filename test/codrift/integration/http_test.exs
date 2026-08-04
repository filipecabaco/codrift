defmodule Codrift.Integration.HTTPTest do
  @moduledoc """
  Body-encoding coverage for the integration HTTP client.

  These exist because of a live defect: every OAuth call went through `post/3`,
  which always sends JSON, while OAuth 2.0 token and device-authorization
  endpoints require `application/x-www-form-urlencoded` (RFC 6749 §4.1.3,
  RFC 8628 §3.1). Linear rejected the PKCE token exchange outright with
  `invalid_request: content must be application/x-www-form-urlencoded`, so
  connecting Linear or GitLab could never have succeeded.

  A real Bandit listener is used rather than a stub, so the assertions are about
  bytes actually put on the wire — which is precisely what the bug was about.
  """
  use ExUnit.Case, async: true

  alias Codrift.Integration.HTTP

  defmodule EchoPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)

      body =
        JSON.encode!(%{
          "content_type" => conn |> get_req_header("content-type") |> List.first(),
          "raw" => raw
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  setup do
    {:ok, sup} = start_supervised({Bandit, plug: EchoPlug, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(sup)
    {:ok, url: "http://127.0.0.1:#{port}/"}
  end

  describe "post_form/3" do
    test "sends an application/x-www-form-urlencoded body", %{url: url} do
      {:ok, echo} = HTTP.post_form(url, %{grant_type: "authorization_code", code: "abc123"})

      assert echo["content_type"] =~ "application/x-www-form-urlencoded"
      refute echo["content_type"] =~ "json"
    end

    test "encodes params as a query string, not JSON", %{url: url} do
      {:ok, echo} = HTTP.post_form(url, %{client_id: "cid", code_verifier: "v-1"})

      assert URI.decode_query(echo["raw"]) == %{"client_id" => "cid", "code_verifier" => "v-1"}
      refute String.starts_with?(echo["raw"], "{")
    end

    test "percent-encodes values that are unsafe in a query string", %{url: url} do
      redirect = "http://127.0.0.1:43117/oauth/callback/linear"
      {:ok, echo} = HTTP.post_form(url, %{redirect_uri: redirect})

      assert echo["raw"] =~ "%3A%2F%2F"
      assert URI.decode_query(echo["raw"]) == %{"redirect_uri" => redirect}
    end
  end

  describe "post/3" do
    test "still sends JSON, so the API adapters are unaffected", %{url: url} do
      {:ok, echo} = HTTP.post(url, %{query: "{ viewer { id } }"})

      assert echo["content_type"] =~ "application/json"
      assert JSON.decode!(echo["raw"]) == %{"query" => "{ viewer { id } }"}
    end
  end
end

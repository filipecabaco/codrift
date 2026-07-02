defmodule Codrift.Web.LocalGuardTest do
  @moduledoc """
  Exercises Codrift.Plugs.LocalGuard end-to-end through the real Francis
  pipeline. The rest of the suite runs with the guard disabled (see
  config/test.exs); this module flips it on so it verifies both that the plug is
  wired ahead of the routes and that its allow/deny logic is correct.

  Not `async`: it mutates the global `:http_guard_enabled` app env.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts Codrift.init([])

  setup do
    prev = Application.get_env(:codrift, :http_guard_enabled)
    Application.put_env(:codrift, :http_guard_enabled, true)
    on_exit(fn -> Application.put_env(:codrift, :http_guard_enabled, prev) end)
    :ok
  end

  defp call(conn), do: Codrift.call(conn, @opts)

  describe "Host allowlist" do
    test "allows a loopback Host" do
      assert %{status: 200} = call(conn(:get, "http://localhost/api/health"))
      assert %{status: 200} = call(conn(:get, "http://127.0.0.1/api/health"))
    end

    test "rejects a non-loopback Host (DNS-rebinding)" do
      conn = call(conn(:get, "http://attacker.example/api/health"))
      assert conn.status == 403
      assert conn.resp_body =~ "non-local Host"
    end

    test "allows Tauri's *.localhost Host" do
      assert %{status: 200} = call(conn(:get, "http://tauri.localhost/api/health"))
    end
  end

  describe "Origin allowlist" do
    test "allows a same-origin (loopback) Origin on a state-changing request" do
      conn =
        conn(
          :post,
          "http://localhost/api/rpc",
          Jason.encode!(%{"name" => "list_initiatives", "args" => %{}})
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "http://localhost:7437")
        |> call()

      assert conn.status == 200
    end

    test "rejects a cross-origin Origin on a state-changing request" do
      conn =
        conn(
          :post,
          "http://localhost/api/rpc",
          Jason.encode!(%{"name" => "list_initiatives", "args" => %{}})
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://evil.example")
        |> call()

      assert conn.status == 403
      assert conn.resp_body =~ "cross-origin"
    end

    test "rejects an opaque (null) Origin" do
      conn =
        conn(:post, "http://localhost/api/rpc", "{}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "null")
        |> call()

      assert conn.status == 403
    end

    test "allows a request with no Origin (MCP client / OAuth redirect)" do
      # No Origin header — e.g. the MCP client POSTing, or the OAuth provider's
      # top-level redirect back to /oauth/callback.
      conn =
        conn(
          :post,
          "http://localhost/mcp",
          Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")
        |> call()

      assert conn.status == 200
    end
  end
end

defmodule Codrift.Web.RoutesTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts Codrift.init([])

  defp get(path) do
    conn(:get, path) |> Codrift.call(@opts)
  end

  defp post_json(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Codrift.call(@opts)
  end

  describe "GET /" do
    test "returns 200 ok" do
      conn = get("/")
      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end

  describe "GET /api/initiatives" do
    test "returns a JSON list" do
      conn = get("/api/initiatives")
      assert conn.status == 200
      assert is_list(Jason.decode!(conn.resp_body))
    end
  end

  describe "GET /api/diff/:initiative_id" do
    test "returns 404 for unknown initiative" do
      conn = get("/api/diff/nonexistent")
      assert conn.status == 404
      assert %{"error" => "initiative not found"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "GET /api/agent/:id" do
    test "returns 404 for unknown agent" do
      conn = get("/api/agent/nonexistent")
      assert conn.status == 404
      assert %{"error" => "agent not found"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "POST /mcp" do
    test "returns MCP initialize response" do
      conn = post_json("/mcp", %{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1})
      assert conn.status == 200

      assert {"content-type", "application/json" <> _} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      body = Jason.decode!(conn.resp_body)
      assert %{"jsonrpc" => "2.0", "id" => 1, "result" => result} = body
      assert %{"protocolVersion" => _, "serverInfo" => %{"name" => "codrift"}} = result
    end

    test "returns tools list" do
      conn = post_json("/mcp", %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 2})
      body = Jason.decode!(conn.resp_body)
      assert %{"result" => %{"tools" => tools}} = body
      tool_names = Enum.map(tools, & &1["name"])
      assert "list_initiatives" in tool_names
      assert "create_initiative" in tool_names
      assert "add_dir" in tool_names
      assert "delete_initiative" in tool_names
      assert "get_diff" in tool_names
      assert "list_agents" in tool_names
    end

    test "create_initiative creates and returns the initiative" do
      conn =
        post_json("/mcp", %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "params" => %{"name" => "create_initiative", "arguments" => %{"name" => "test-init"}},
          "id" => 10
        })

      body = Jason.decode!(conn.resp_body)
      assert %{"result" => %{"content" => [%{"text" => json}]}} = body
      assert %{"id" => _, "name" => "test-init"} = Jason.decode!(json)
    end

    test "delete_initiative returns MCP error for unknown id" do
      conn =
        post_json("/mcp", %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "params" => %{
            "name" => "delete_initiative",
            "arguments" => %{"initiative_id" => "nonexistent"}
          },
          "id" => 11
        })

      body = Jason.decode!(conn.resp_body)
      assert %{"error" => %{"message" => message}} = body
      assert String.contains?(message, "not found")
    end

    test "returns error for unknown method" do
      conn = post_json("/mcp", %{"jsonrpc" => "2.0", "method" => "unknown/method", "id" => 3})
      body = Jason.decode!(conn.resp_body)
      assert %{"error" => %{"code" => -32_601}} = body
    end

    test "returns invalid request error for missing id" do
      conn = post_json("/mcp", %{"jsonrpc" => "2.0", "method" => "tools/list"})
      body = Jason.decode!(conn.resp_body)
      assert %{"error" => %{"code" => code}} = body
      assert code in [-32_600, -32_601]
    end

    test "returns empty body as invalid request when content-type is missing" do
      conn =
        conn(:post, "/mcp", "")
        |> Codrift.call(@opts)

      body = Jason.decode!(conn.resp_body)
      assert %{"error" => _} = body
    end
  end

  describe "unmatched routes" do
    test "returns 404 for unknown path" do
      conn = get("/no/such/route")
      assert conn.status == 404
    end
  end
end

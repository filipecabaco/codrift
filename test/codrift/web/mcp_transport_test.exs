defmodule Codrift.Web.MCPTransportTest do
  @moduledoc """
  End-to-end coverage of both MCP transports over a real socket.

  This is the regression test for the bug that made the Codrift MCP server look
  permanently unavailable. Registrations pointed at `/mcp/sse` with
  `--transport sse`, but `POST /mcp` answered in the HTTP body — and under
  HTTP+SSE the client ignores that body and waits for the response on the SSE
  stream. Nothing was ever written to the stream, so `initialize` never
  resolved and the client sat there until it timed out, with no error to
  explain it.

  Plug.Test cannot catch that: the whole failure lives in the relationship
  between two separate HTTP requests, and its SSE loop never returns a conn.
  So this runs a loopback Bandit on an ephemeral port and speaks raw HTTP with
  `:gen_tcp`, holding the stream open across the POST the way a real client
  does.

  Not `async`: it binds a real listening socket.
  """
  use ExUnit.Case, async: false

  @initialize %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "test", "version" => "1"}
    }
  }

  setup_all do
    pid =
      start_supervised!(
        {Bandit, plug: Codrift, scheme: :http, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{port: port}
  end

  describe "streamable HTTP (POST /mcp)" do
    test "answers in the response body", %{port: port} do
      assert {200, headers, body} = request(port, "POST", "/mcp", @initialize)
      assert headers["content-type"] =~ "application/json"

      assert %{"id" => 1, "result" => %{"serverInfo" => %{"name" => "codrift"}}} =
               Jason.decode!(body)
    end

    # A notification carries a method but no id, and JSON-RPC forbids answering
    # one. Codrift used to reply `-32600 Invalid request` with a null id to
    # every `notifications/initialized`, i.e. to the one message that must not
    # be responded to.
    test "acknowledges a notification without a JSON-RPC response", %{port: port} do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert {202, _headers, ""} = request(port, "POST", "/mcp", notification)
    end

    test "still reports a bad request that does carry an id", %{port: port} do
      bad = %{"jsonrpc" => "2.0", "id" => 9, "method" => "unknown/method"}
      assert {200, _headers, body} = request(port, "POST", "/mcp", bad)
      assert %{"id" => 9, "error" => %{"code" => -32_601}} = Jason.decode!(body)
    end

    # There is no server-initiated stream on this route and no session to tear
    # down. 405 says which methods do work; a 404 would read as "no server
    # here" to a client probing for the optional GET stream.
    test "GET and DELETE report method-not-allowed, not missing", %{port: port} do
      for method <- ["GET", "DELETE"] do
        assert {405, headers, _body} = request(port, method, "/mcp", nil)
        assert headers["allow"] == "POST"
      end
    end
  end

  describe "HTTP+SSE (GET /mcp/sse)" do
    test "delivers the response to a POST down the session's stream", %{port: port} do
      {stream, session_id} = open_sse(port)

      # The POST is only acknowledged — 202, empty body. A client on this
      # transport is not reading it.
      assert {202, _headers, ""} =
               request(port, "POST", "/mcp?sessionId=#{session_id}", @initialize)

      assert {"message", data} = read_event(stream)

      assert %{"id" => 1, "result" => %{"serverInfo" => %{"name" => "codrift"}}} =
               Jason.decode!(data)

      :gen_tcp.close(stream)
    end

    test "the endpoint event names a session rather than a bare path", %{port: port} do
      {stream, session_id} = open_sse(port)
      assert session_id != ""
      :gen_tcp.close(stream)
    end

    test "two streams get distinct sessions", %{port: port} do
      {a, id_a} = open_sse(port)
      {b, id_b} = open_sse(port)
      refute id_a == id_b
      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end

    # A stale id must not resolve to somebody else's stream, and a client that
    # posts to one needs to hear about it rather than block forever.
    test "an unknown session is rejected", %{port: port} do
      assert {404, _headers, _body} =
               request(port, "POST", "/mcp?sessionId=nonexistent", @initialize)
    end

    test "a closed stream stops accepting posts for its session", %{port: port} do
      {stream, session_id} = open_sse(port)
      :gen_tcp.close(stream)
      # Registry unregisters on owner exit; give Bandit a moment to notice.
      wait_until(fn ->
        match?({404, _, _}, request(port, "POST", "/mcp?sessionId=#{session_id}", @initialize))
      end)
    end
  end

  # ── Raw HTTP helpers ─────────────────────────────────────────────────────────

  # One request per connection, `Connection: close`, so the body is everything
  # up to EOF and no chunked-encoding parsing is needed.
  defp request(port, method, path, body) do
    {:ok, socket} = connect(port)

    payload =
      case body do
        nil -> ""
        map -> Jason.encode!(map)
      end

    head =
      "#{method} #{path} HTTP/1.1\r\n" <>
        "Host: localhost\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(payload)}\r\n" <>
        "Connection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, head <> payload)
    raw = read_until_closed(socket, "")
    :gen_tcp.close(socket)

    [head_raw, body_raw] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head_raw, "\r\n")
    [_http, status | _rest] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ": ", parts: 2)
        {String.downcase(name), value}
      end)

    {String.to_integer(status), headers, body_raw}
  end

  # Opens the SSE stream and returns it still open, alongside the session id the
  # server advertised. The stream has to stay open: it owns the registry entry
  # the POST looks up.
  defp open_sse(port) do
    {:ok, socket} = connect(port)

    :ok =
      :gen_tcp.send(
        socket,
        "GET /mcp/sse HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n\r\n"
      )

    assert {"endpoint", endpoint} = read_event(socket)
    assert [_path, query] = String.split(endpoint, "?", parts: 2)
    assert "sessionId=" <> session_id = query

    {socket, session_id}
  end

  # Reads until one complete SSE event (`\n\n`-terminated) has arrived, skipping
  # the response head and the `: keepalive` comments Francis emits.
  defp read_event(socket, buffer \\ "") do
    case String.split(buffer, "\n\n", parts: 2) do
      [chunk, rest] ->
        case parse_event(chunk) do
          nil -> read_event(socket, rest)
          event -> event
        end

      [_partial] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_event(socket, buffer <> data)
    end
  end

  defp parse_event(chunk) do
    lines = chunk |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, "\r"))

    with event when is_binary(event) <- field(lines, "event: "),
         data when is_binary(data) <- field(lines, "data: ") do
      {event, data}
    else
      _ -> nil
    end
  end

  defp field(lines, prefix) do
    case Enum.find(lines, &String.starts_with?(&1, prefix)) do
      nil -> nil
      line -> String.replace_prefix(line, prefix, "")
    end
  end

  defp connect(port),
    do: :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)

  defp read_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_until_closed(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end

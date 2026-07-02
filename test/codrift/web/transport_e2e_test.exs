defmodule Codrift.Web.TransportE2ETest do
  @moduledoc """
  End-to-end coverage of the real-time transports over an actual socket:

    - `GET /events/initiative/:id` (SSE) — the "watch agents live" output stream
    - `ws /ws/agent/:agent_id`      (WS)  — the keystroke/resize input channel

  Plug.Test can't exercise these (Bandit performs the SSE chunking and the WS
  upgrade below the plug seam), so this spins up a dedicated loopback Bandit on
  an ephemeral port and speaks raw HTTP/WS to it with `:gen_tcp`. A live PTY
  agent (`terminal` adapter) provides the output that should flow over SSE and
  the process that should receive WS input.

  Not `async`: uses the global agent supervisor and a real listening socket.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Bitwise, only: [|||: 2]

  @opts Codrift.init([])

  setup_all do
    pid =
      start_supervised!(
        {Bandit, plug: Codrift, scheme: :http, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{port: port}
  end

  # ── Core helpers (drive the backend via the in-process plug) ──────────────────

  defp rpc(name, args) do
    conn(:post, "/api/rpc", Jason.encode!(%{"name" => name, "args" => args}))
    |> put_req_header("content-type", "application/json")
    |> Codrift.call(@opts)
    |> then(&{&1.status, Jason.decode!(&1.resp_body)})
  end

  defp ok!(name, args) do
    assert {200, %{"ok" => result}} = rpc(name, args)
    result
  end

  # Starts an initiative + a live terminal agent, waits until the shell has
  # emitted its first output (so it's ready for input), and cleans both up.
  defp start_live_agent(tmp_dir) do
    id =
      ok!("create_initiative", %{
        "name" => "tx-#{System.unique_integer([:positive])}",
        "dirs" => []
      })["id"]

    on_exit(fn -> rpc("delete_initiative", %{"initiative_id" => id}) end)

    agent_id =
      ok!("start_agent", %{"initiative_id" => id, "dir" => tmp_dir, "adapter" => "terminal"})[
        "id"
      ]

    on_exit(fn -> rpc("stop_agent", %{"agent_id" => agent_id}) end)

    assert eventually(fn -> agent_output(agent_id) != "" end),
           "shell agent never produced startup output"

    {id, agent_id}
  end

  defp agent_output(agent_id) do
    %{"output" => chunks} = ok!("get_agent_output", %{"agent_id" => agent_id, "n" => 400})
    Enum.join(chunks)
  end

  # ── Raw socket helpers ────────────────────────────────────────────────────────

  defp connect(port) do
    {:ok, sock} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    sock
  end

  # Reads from the socket until `needle` appears in the accumulated bytes, or the
  # deadline passes. Returns the accumulated string (asserts on the needle).
  defp read_until(sock, needle, timeout_ms \\ 4_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    read_until_loop(sock, needle, "", deadline)
  end

  defp read_until_loop(sock, needle, acc, deadline) do
    cond do
      String.contains?(acc, needle) ->
        acc

      System.monotonic_time(:millisecond) > deadline ->
        acc

      true ->
        case :gen_tcp.recv(sock, 0, 500) do
          {:ok, data} -> read_until_loop(sock, needle, acc <> data, deadline)
          {:error, :timeout} -> read_until_loop(sock, needle, acc, deadline)
          {:error, _} -> acc
        end
    end
  end

  defp eventually(fun, attempts \\ 80, sleep_ms \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: :timer.sleep(sleep_ms) && {:cont, false}
    end)
  end

  # Minimal RFC 6455 client text frame (FIN + text opcode, masked as clients must).
  defp ws_text_frame(payload) do
    len = byte_size(payload)
    true = len < 126
    mask = :crypto.strong_rand_bytes(4)
    masked = mask_payload(payload, mask)
    <<0x81, 0x80 ||| len>> <> mask <> masked
  end

  defp mask_payload(payload, mask) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(mask, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  import Bitwise, only: [|||: 2]

  # ── SSE: live output stream ───────────────────────────────────────────────────

  describe "SSE /events/initiative/:id" do
    @tag :tmp_dir
    test "streams the connected event and then agent output", %{port: port, tmp_dir: tmp_dir} do
      {initiative_id, agent_id} = start_live_agent(tmp_dir)

      sock = connect(port)

      req =
        "GET /events/initiative/#{initiative_id} HTTP/1.1\r\n" <>
          "Host: localhost\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n"

      :ok = :gen_tcp.send(sock, req)

      # The join reply.
      assert read_until(sock, "event: connected") =~ "event: connected"

      # Now type into the subscribed agent; its output must arrive as an SSE
      # `output` event carrying base64 content.
      _ = ok!("send_to_agent", %{"agent_id" => agent_id, "input" => "echo SSE_STREAM_OK\n"})

      assert read_until(sock, "event: output") =~ "event: output"

      :gen_tcp.close(sock)
    end
  end

  # ── WS: input channel ─────────────────────────────────────────────────────────

  describe "WS /ws/agent/:agent_id" do
    @tag :tmp_dir
    test "a data frame is delivered to the agent's PTY", %{port: port, tmp_dir: tmp_dir} do
      {_initiative_id, agent_id} = start_live_agent(tmp_dir)

      sock = connect(port)
      key = Base.encode64(:crypto.strong_rand_bytes(16))

      handshake =
        "GET /ws/agent/#{agent_id} HTTP/1.1\r\n" <>
          "Host: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"

      :ok = :gen_tcp.send(sock, handshake)
      assert read_until(sock, "101") =~ "101 Switching Protocols"

      # Send a keystroke frame; the handler routes {"t":"d"} to the PTY.
      frame = ws_text_frame(~s({"t":"d","d":"echo WS_INPUT_OK\\n"}))
      :ok = :gen_tcp.send(sock, frame)

      # Output flows back over SSE, not WS — verify via the agent's buffer that
      # the PTY actually received (and echoed) our input.
      assert eventually(fn -> String.contains?(agent_output(agent_id), "WS_INPUT_OK") end),
             "agent PTY never received the WS input frame"

      :gen_tcp.close(sock)
    end
  end
end

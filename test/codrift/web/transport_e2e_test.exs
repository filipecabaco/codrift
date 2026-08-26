defmodule Codrift.Web.TransportE2ETest do
  @moduledoc """
  End-to-end coverage of `ws /ws` over a real socket.

  Plug.Test can't exercise this (Bandit performs the WS upgrade below the plug
  seam), so this runs a loopback Bandit on an ephemeral port and speaks raw
  HTTP/WS with `:gen_tcp`, against a live PTY agent.

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

    # Don't wait for a spontaneous PS1 prompt — minimal CI shells (bash without a
    # profile) print none. Nudge the PTY with a marker command and wait until it
    # comes back, which proves the shell is live and *running* what it is sent.
    #
    # The marker is arithmetic the shell has to evaluate, so what appears on
    # screen while the command is being typed can never contain it. An
    # interactive shell echoes as it goes, and `send_to_agent` writes the body
    # and the Enter as two writes, so "the text is visible" and "the shell ran
    # it" are genuinely different moments — a nudge whose literal text is the
    # marker cannot tell them apart, and the caller proceeds against a shell
    # that has not started.
    n = System.unique_integer([:positive])
    marker = "READY_#{n}"
    _ = ok!("send_to_agent", %{"agent_id" => agent_id, "input" => "echo READY_$((#{n}))"})

    assert eventually(fn -> String.contains?(agent_output(agent_id), marker) end),
           "shell agent never became ready (no echo of nudge command)"

    {id, agent_id}
  end

  defp agent_output(agent_id) do
    %{"output" => chunks} = ok!("get_agent_output", %{"agent_id" => agent_id, "n" => 400})
    Enum.join(chunks)
  end

  # ── Raw socket helpers ────────────────────────────────────────────────────────

  defp ws_connect(port, path) do
    {:ok, sock} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    :ok = :gen_tcp.send(sock, ws_handshake(path))

    {upgrade, rest} = read_until(sock, "101 Switching Protocols", "")
    assert upgrade =~ "101 Switching Protocols"

    {joined, rest} = read_until(sock, ~s("event":"connected"), rest)
    assert joined =~ ~s("event":"connected")

    {sock, rest}
  end

  # Returns {read, rest}. Thread `rest` into the next call: Bandit packs the
  # upgrade response and several frames into one segment.
  defp read_until(sock, needle, rest, timeout_ms \\ 4_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    read_until_loop(sock, needle, rest, deadline)
  end

  defp read_until_loop(sock, needle, acc, deadline) do
    case String.split(acc, needle, parts: 2) do
      [_matched, tail] -> {acc, tail}
      [_unmatched] -> read_more(sock, needle, acc, deadline)
    end
  end

  defp read_more(sock, needle, acc, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {acc, ""}
    else
      case :gen_tcp.recv(sock, 0, 500) do
        {:ok, data} -> read_until_loop(sock, needle, acc <> data, deadline)
        {:error, :timeout} -> read_until_loop(sock, needle, acc, deadline)
        {:error, _} -> {acc, ""}
      end
    end
  end

  defp eventually(fun, attempts \\ 80, sleep_ms \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: :timer.sleep(sleep_ms) && {:cont, false}
    end)
  end

  defp ws_handshake(path) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    "GET #{path} HTTP/1.1\r\n" <>
      "Host: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
      "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
  end

  # RFC 6455 client text frame, masked, with extended length forms.
  defp ws_text_frame(payload) do
    mask = :crypto.strong_rand_bytes(4)
    masked = mask_payload(payload, mask)

    header =
      case byte_size(payload) do
        len when len < 126 -> <<0x81, 0x80 ||| len>>
        len when len < 65_536 -> <<0x81, 0x80 ||| 126, len::16>>
        len -> <<0x81, 0x80 ||| 127, len::64>>
      end

    header <> mask <> masked
  end

  defp mask_payload(payload, mask) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(mask, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  import Bitwise, only: [|||: 2]

  # ── The unified initiative socket ─────────────────────────────────────────────

  describe "ws /ws" do
    @tag :tmp_dir
    test "streams the connected frame, then agent output, and accepts input", %{
      port: port,
      tmp_dir: tmp_dir
    } do
      {_initiative_id, agent_id} = start_live_agent(tmp_dir)

      {sock, rest} = ws_connect(port, "/ws")

      # Down: the agent's output arrives as an `output` frame.
      _ = ok!("send_to_agent", %{"agent_id" => agent_id, "input" => "echo WS_STREAM_OK\n"})
      {output, _rest} = read_until(sock, ~s("event":"output"), rest)
      assert output =~ ~s("event":"output")

      # Up: a keystroke frame on the same socket reaches the PTY.
      frame =
        ws_text_frame(~s({"t":"d","agent_id":"#{agent_id}","d":"echo WS_INPUT_OK\\n"}))

      :ok = :gen_tcp.send(sock, frame)

      assert eventually(fn -> String.contains?(agent_output(agent_id), "WS_INPUT_OK") end),
             "agent PTY never received the input frame"

      :gen_tcp.close(sock)
    end

    # Francis defaults max_frame_size to 64 KB; the route raises it, since a
    # paste arrives as one frame.
    @tag :tmp_dir
    test "accepts a paste larger than the default frame limit", %{port: port, tmp_dir: tmp_dir} do
      {_initiative_id, agent_id} = start_live_agent(tmp_dir)

      {sock, rest} = ws_connect(port, "/ws")

      # ~100 KB of pasted text in one frame.
      big = String.duplicate("x", 100_000)

      :ok =
        :gen_tcp.send(sock, ws_text_frame(~s({"t":"d","agent_id":"#{agent_id}","d":"#{big}"})))

      # Survival is read off the socket, not off the shell: the bytes reach the
      # PTY and come straight back as `output` frames, which is the entire
      # claim — an oversized frame is accepted and the connection stays usable.
      #
      # Asking the shell to *run* something afterwards made this a test of how
      # fast zsh's line editor can redraw a 100 000-character line instead. When
      # it takes the per-character path (`x \e[K\e[K`, over and over) that is
      # effectively unbounded, and the test either passed in 50 ms or hung.
      {output, _rest} = read_until(sock, ~s("event":"output"), rest)
      assert output =~ ~s("event":"output"), "socket died on an oversized frame"

      :gen_tcp.close(sock)
    end

    @tag :tmp_dir
    test "an agent started after the socket connected is announced and streams", %{
      port: port,
      tmp_dir: tmp_dir
    } do
      initiative_id =
        ok!("create_initiative", %{
          "name" => "tx-late-#{System.unique_integer([:positive])}",
          "dirs" => []
        })["id"]

      on_exit(fn -> rpc("delete_initiative", %{"initiative_id" => initiative_id}) end)

      {sock, rest} = ws_connect(port, "/ws")

      # Started *after* the connection: the watcher registry has to wire it up.
      agent_id =
        ok!("start_agent", %{
          "initiative_id" => initiative_id,
          "dir" => tmp_dir,
          "adapter" => "terminal"
        })["id"]

      on_exit(fn -> rpc("stop_agent", %{"agent_id" => agent_id}) end)

      # Announced without a refresh, so an orchestrator's sub-agents appear live.
      {announced, rest} = read_until(sock, ~s("event":"agent_started"), rest)
      assert announced =~ agent_id

      _ = ok!("send_to_agent", %{"agent_id" => agent_id, "input" => "echo LATE_AGENT_OK\n"})

      {output, _rest} = read_until(sock, ~s("event":"output"), rest)
      assert output =~ ~s("event":"output")

      :gen_tcp.close(sock)
    end
  end
end

defmodule Codrift.AgentProcessTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.AgentProcess
  alias Codrift.Test.EchoAdapter

  defp start_agent(opts \\ []) do
    id = Keyword.get(opts, :id, "test-#{:erlang.unique_integer([:positive])}")
    dir = Keyword.get(opts, :dir, System.tmp_dir!())
    adapter = Keyword.get(opts, :adapter, EchoAdapter)

    start_supervised!(
      {AgentProcess,
       [id: id, initiative_id: "test-init", dir: dir, adapter: adapter] ++
         Keyword.take(opts, [:command, :extra_args])}
    )
  end

  test "starts with :starting status" do
    pid = start_agent()
    assert %{status: :starting} = AgentProcess.status(pid)
  end

  test "status includes id, initiative_id, dir, and adapter" do
    dir = System.tmp_dir!()
    pid = start_agent(id: "my-id", dir: dir)

    assert %{
             id: "my-id",
             initiative_id: "test-init",
             dir: ^dir,
             adapter: EchoAdapter,
             status: :starting
           } = AgentProcess.status(pid)
  end

  test "subscribe delivers output notifications to caller" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    AgentProcess.send_input(pid, "ping")

    assert_receive {:agent_output, _id, data}, 1_000
    assert String.contains?(data, "ping")
  end

  test "receives output from the process and buffers it" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    AgentProcess.send_input(pid, "hello from test")
    assert_receive {:agent_output, _id, _data}, 1_000

    refute Enum.empty?(AgentProcess.recent_output(pid))
  end

  test "recent_output returns lines in chronological order" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    AgentProcess.send_input(pid, "alpha")
    assert_receive {:agent_output, _, _}, 500

    AgentProcess.send_input(pid, "beta")
    assert_receive {:agent_output, _, _}, 500

    joined = pid |> AgentProcess.recent_output() |> Enum.join()

    assert String.contains?(joined, "alpha")
    assert String.contains?(joined, "beta")

    {alpha_pos, _} = :binary.match(joined, "alpha")
    {beta_pos, _} = :binary.match(joined, "beta")
    assert alpha_pos < beta_pos, "expected 'alpha' before 'beta' in output"
  end

  test "parse_status updates status on matching output" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    AgentProcess.send_input(pid, "READY")
    assert_receive {:agent_output, _, _}, 500

    assert %{status: :awaiting_input} = AgentProcess.status(pid)
  end

  test "subscriber is cleaned up when it exits" do
    pid = start_agent()

    subscriber = spawn(fn -> receive do: (_ -> :ok) end)
    :ok = AgentProcess.subscribe(pid, subscriber)
    Process.exit(subscriber, :kill)

    :timer.sleep(50)

    assert Process.alive?(pid)
    assert %{status: _} = AgentProcess.status(pid)
  end

  test "send_input is a no-op when agent is stopped" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    :sys.replace_state(pid, &%{&1 | status: :stopped})

    AgentProcess.send_input(pid, "should be ignored")

    refute_receive {:agent_output, _, _}, 100
    assert Process.alive?(pid)
  end

  test "buffer is capped at 1000 entries" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    for i <- 1..120 do
      AgentProcess.send_input(pid, "line #{i}")
      assert_receive {:agent_output, _, _}, 500
    end

    output = AgentProcess.recent_output(pid, 2_000)
    assert length(output) <= 1_000
    assert output != []
  end

  describe "exit status" do
    test "clean exit sets status to :stopped" do
      pid = start_agent(adapter: Codrift.Test.CleanExitAdapter)
      assert await_status(pid, :stopped)
    end

    test "non-zero exit sets status to :crashed" do
      pid = start_agent(adapter: Codrift.Test.CrashExitAdapter)
      assert await_status(pid, :crashed)
    end

    # erlexec reports the raw `waitpid` status word, so an exit code of 127
    # arrives as 32512 — which is the number the terminal used to print back.
    test "a PTY exit code is decoded from the raw wait status" do
      id = "pty-crash-#{:erlang.unique_integer([:positive])}"
      pid = start_agent(id: id, adapter: Codrift.Test.PtyCrashExitAdapter)

      assert await_status(pid, :crashed)

      log = File.read!(Codrift.Paths.agent_log("test-init", id))
      assert log =~ "[agent exited with code 127]"
      refute log =~ "32512"
    end

    test "a signalled agent is named by its signal and counts as stopped" do
      id = "pty-signal-#{:erlang.unique_integer([:positive])}"
      pid = start_agent(id: id, adapter: Codrift.Test.PtySignalExitAdapter)

      assert await_status(pid, :stopped)

      assert File.read!(Codrift.Paths.agent_log("test-init", id)) =~
               "[agent terminated by SIGTERM]"
    end

    # A shell exits with whatever its last command returned, so a non-zero code
    # says nothing about the terminal — closing one is just closing one.
    test "a terminal is :stopped whatever its shell exits with" do
      pid =
        start_agent(
          adapter: Codrift.Agent.Adapters.Terminal,
          command: System.find_executable("sh") || "/bin/sh",
          extra_args: ["-c", "exit 127"]
        )

      assert await_status(pid, :stopped)
    end
  end

  describe "transcript log" do
    test "output is appended to the durable per-agent log" do
      id = "log-test-#{:erlang.unique_integer([:positive])}"
      pid = start_agent(id: id)
      :ok = AgentProcess.subscribe(pid)

      AgentProcess.send_input(pid, "transcript-ping")
      assert_receive {:agent_output, _, _}, 1_000

      assert File.read!(Codrift.Paths.agent_log("test-init", id)) =~ "transcript-ping"
    end

    test "exit marker is written to the log on a crash" do
      id = "log-crash-#{:erlang.unique_integer([:positive])}"
      pid = start_agent(id: id, adapter: Codrift.Test.CrashExitAdapter)
      assert await_status(pid, :crashed)

      assert File.read!(Codrift.Paths.agent_log("test-init", id)) =~
               "[agent exited with code 3]"
    end
  end

  describe "inherited release environment" do
    # Codrift's own release env leaks into everything it spawns. The one that
    # bites is RELEASE_SYS_CONFIG: a boot script only defaults it, so the
    # inherited value wins and pins a child release's config provider to the
    # *app's* version — `codrift memory add` from an agent then dies with
    # "could not read .../releases/<app version>/runtime.exs" whenever the CLI
    # and the app are on different versions, which is every user mid-upgrade.
    setup do
      vars = %{
        "RELEASE_SYS_CONFIG" => "/from/the/desktop/sidecar/sys",
        "RELEASE_ROOT" => "/from/the/desktop/sidecar",
        "__BURRITO" => "1"
      }

      System.put_env(vars)
      on_exit(fn -> Enum.each(vars, fn {k, _} -> System.delete_env(k) end) end)
      :ok
    end

    test "is not passed to an agent spawned on the port path" do
      pid = start_agent(adapter: Codrift.Test.EnvAdapter)
      :ok = AgentProcess.subscribe(pid)
      assert_receive {:agent_output, _, _}, 2_000

      env = collect_output(pid)

      refute env =~ "RELEASE_SYS_CONFIG"
      refute env =~ "RELEASE_ROOT"
      # Codrift.desktop_sidecar?/0 reads __BURRITO, so a leaked copy makes a
      # child believe it is the desktop sidecar.
      refute env =~ "__BURRITO"
    end

    test "is not passed to an agent spawned on the PTY path" do
      pid = start_agent(adapter: Codrift.Test.PtyEnvAdapter)
      :ok = AgentProcess.subscribe(pid)
      assert_receive {:agent_output, _, _}, 2_000

      env = collect_output(pid)

      refute env =~ "RELEASE_SYS_CONFIG"
      refute env =~ "RELEASE_ROOT"
      refute env =~ "__BURRITO"
      # Guards the unset list against being applied so broadly that the agent
      # loses the environment it needs.
      assert env =~ "PATH="
    end
  end

  # The output buffer is the hottest path in Codrift — a full-screen TUI emits a
  # chunk per repaint — and it is also the one place an idle agent can quietly
  # accumulate memory for the rest of the day. Both caps exist for that: a count
  # so the queue stays cheap, and a byte ceiling because "a chunk" is whatever
  # the process happened to flush, which leaves the count alone saying nothing
  # about actual memory.
  describe "output buffer limits" do
    @count_limit 1_000
    @byte_limit 1_048_576

    defp drain_until(marker, timeout \\ 15_000) do
      receive do
        {:agent_output, _id, data} ->
          if String.contains?(data, marker), do: :ok, else: drain_until(marker, timeout)
      after
        timeout -> flunk("never saw #{marker} in the agent's output")
      end
    end

    defp flood(pid) do
      :ok = AgentProcess.subscribe(pid)
      AgentProcess.send_input(pid, "OLDEST-MARKER")

      # ~1.6 MB, comfortably past the byte cap.
      filler = String.duplicate("x", 4_000)
      for i <- 1..400, do: AgentProcess.send_input(pid, "line#{i}-#{filler}")

      AgentProcess.send_input(pid, "NEWEST-MARKER")
      drain_until("NEWEST-MARKER")
      AgentProcess.recent_output(pid, 1_000_000)
    end

    test "holds to both the count and the byte ceiling" do
      out = flood(start_agent())

      assert length(out) <= @count_limit
      assert out |> Enum.map(&byte_size/1) |> Enum.sum() <= @byte_limit
    end

    test "evicts the oldest output and keeps the newest" do
      joined = start_agent() |> flood() |> Enum.join()

      refute String.contains?(joined, "OLDEST-MARKER")
      assert String.contains?(joined, "NEWEST-MARKER")
    end

    test "eviction preserves chronological order" do
      joined = start_agent() |> flood() |> Enum.join()

      numbers =
        ~r/line(\d+)-/
        |> Regex.scan(joined)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)

      refute Enum.empty?(numbers)
      assert numbers == Enum.sort(numbers)
    end

    test "a quiet agent keeps everything it produced" do
      pid = start_agent()
      :ok = AgentProcess.subscribe(pid)

      AgentProcess.send_input(pid, "alpha")
      AgentProcess.send_input(pid, "omega")
      drain_until("omega")

      joined = pid |> AgentProcess.recent_output(1_000_000) |> Enum.join()
      assert String.contains?(joined, "alpha")
      assert String.contains?(joined, "omega")
    end
  end

  # Sending a prompt and reading the result back are the two halves of running an
  # agent from an orchestrator, and both were broken at once: the prompt was
  # typed but never submitted, and the only way to notice that raised.
  describe "submitting input on the PTY path" do
    test "the prompt body and its Enter arrive as two separate writes" do
      pid = start_agent(adapter: Codrift.Test.PtyCatAdapter)
      :ok = AgentProcess.subscribe(pid)

      # `cat` behind a canonical-mode tty is only handed a line once a
      # terminator reaches it, so "omega" coming back is proof the Enter landed
      # — and *when* it comes back is proof of whether it landed as its own
      # keystroke or as the tail of one burst write. Written together, this
      # produced a single "alpha\r\nomega\r\n\r\n" chunk, which is the shape a
      # TUI reads as a paste (and note the extra blank line the LF submitted).
      AgentProcess.send_input(pid, "alpha\nomega")

      early = output_within(80)
      assert early =~ "alpha", "the prompt body never reached the pty"

      refute early =~ "omega",
             "prompt body and Enter were written together; a TUI reads that as a paste"

      assert await_output("omega", 2_000), "the deferred Enter never arrived"
    end

    test "a keystroke cannot overtake the Enter deferred behind a prompt" do
      pid = start_agent(adapter: Codrift.Test.PtyCatAdapter)
      :ok = AgentProcess.subscribe(pid)

      AgentProcess.send_input(pid, "alpha")
      AgentProcess.send_raw(pid, "beta\r")

      joined = collect_output(pid)

      # Keystrokes from the UI arrive on the raw path, and the tty has a single
      # line buffer for both paths. If the raw write jumped the queued Enter,
      # `cat` was handed one line reading "alphabeta" instead of two.
      assert joined =~ "alpha"
      assert joined =~ "beta"
      refute joined =~ "alphabeta", "a raw keystroke overtook the deferred Enter"
    end

    test "status is :input_pending until the Enter has actually been written" do
      pid = start_agent(adapter: Codrift.Test.PtyCatAdapter)

      AgentProcess.send_input(pid, "alpha")

      # The old handler claimed :running here, which is what let an orchestrator
      # poll forever at an agent that had never started.
      assert %{status: :input_pending} = AgentProcess.status(pid)
      assert await_status(pid, :running)
    end
  end

  # A PTY read ends on a byte boundary, so a TUI drawing box characters,
  # spinners and emoji hands us a split codepoint constantly. `get_agent_output`
  # JSON-encodes what comes back, and an incomplete sequence raised
  # :unexpected_end — every call, for the whole life of the agent.
  describe "output split across reads" do
    # "├" and "─" are three bytes each; cutting at 4 leaves the first chunk
    # ending on a lone leading byte, exactly as a read boundary does.
    @box "├─ tool result"

    test "a split codepoint still yields JSON-encodable output" do
      pid = start_agent()
      port = :sys.get_state(pid).port
      <<head::binary-size(4), tail::binary>> = @box

      send(pid, {port, {:data, head}})
      send(pid, {port, {:data, tail}})

      output = AgentProcess.recent_output(pid, 50)

      assert JSON.encode!(%{"output" => output}) =~ "tool result"
      assert output |> Enum.join() |> String.contains?(@box)
    end

    test "no subscriber is ever handed half a codepoint" do
      pid = start_agent()
      port = :sys.get_state(pid).port
      :ok = AgentProcess.subscribe(pid)
      <<head::binary-size(4), tail::binary>> = @box

      send(pid, {port, {:data, head}})
      assert_receive {:agent_output, _, first}, 500
      assert String.valid?(first)

      send(pid, {port, {:data, tail}})
      assert_receive {:agent_output, _, second}, 500
      assert String.valid?(second)

      assert first <> second == @box
    end
  end

  # `env` writes its whole environment in one go, but it can still arrive in
  # several chunks; drain before asserting on absence.
  defp collect_output(pid) do
    receive do
      {:agent_output, _, _} -> collect_output(pid)
    after
      200 -> pid |> AgentProcess.recent_output() |> Enum.join()
    end
  end

  # Everything the agent emits in the next `ms`, joined.
  #
  # These assert on *content over a window*, never on which chunk carried what:
  # how a tty splits one write across reads is a platform detail. macOS hands
  # back "alpha\r\n" in one go where Linux splits it into "alpha" and "\r\n",
  # and an assertion phrased as "nothing else arrives for 80ms" fails on the
  # second for reasons that have nothing to do with what it is testing.
  defp output_within(ms) do
    collect_within(System.monotonic_time(:millisecond) + ms, "")
  end

  defp collect_within(deadline, acc) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left <= 0 ->
        acc

      left ->
        receive do
          {:agent_output, _, data} -> collect_within(deadline, acc <> data)
        after
          left -> acc
        end
    end
  end

  # Waits for `needle`, across however many chunks it takes to arrive.
  defp await_output(needle, ms) do
    await_output(needle, System.monotonic_time(:millisecond) + ms, "")
  end

  defp await_output(needle, deadline, acc) do
    if String.contains?(acc, needle) do
      true
    else
      case deadline - System.monotonic_time(:millisecond) do
        left when left <= 0 ->
          false

        left ->
          receive do
            {:agent_output, _, data} -> await_output(needle, deadline, acc <> data)
          after
            left -> false
          end
      end
    end
  end

  defp await_status(pid, status, tries \\ 100) do
    cond do
      AgentProcess.status(pid).status == status -> true
      tries == 0 -> AgentProcess.status(pid).status
      true -> Process.sleep(20) && await_status(pid, status, tries - 1)
    end
  end
end

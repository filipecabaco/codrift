defmodule Codrift.ConductorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.{AgentProcess, AgentSupervisor, Conductor}
  alias Codrift.Test.EchoAdapter

  setup do
    agent_sup = start_supervised!({AgentSupervisor, name: nil})
    dir = System.tmp_dir!()
    %{agent_sup: agent_sup, dir: dir}
  end

  defp start_conductor(initiative_id, dirs, opts \\ []) do
    agent_sup = Keyword.fetch!(opts, :agent_sup)
    task = Keyword.get(opts, :task)
    context_dir = Keyword.get(opts, :context_dir)

    child_opts =
      [initiative_id: initiative_id, dirs: dirs, adapter: EchoAdapter, agent_supervisor: agent_sup] ++
        if(task, do: [task: task], else: []) ++
        if(context_dir, do: [context_dir: context_dir], else: [])

    start_supervised!({Conductor, child_opts})
  end

  # ── Fan-out mode ─────────────────────────────────────────────────────────────

  describe "fan-out mode" do
    test "starts one agent per directory", %{agent_sup: sup, dir: dir} do
      dir2 = System.tmp_dir!()
      pid = start_conductor("init-fanout", [dir, dir2], agent_sup: sup)

      :timer.sleep(100)
      assert map_size(Conductor.agent_status(pid)) == 2
    end

    test "skips directories that do not exist on disk", %{agent_sup: sup} do
      pid = start_conductor("init-skip", ["/nonexistent/abc123"], agent_sup: sup)

      :timer.sleep(50)
      assert map_size(Conductor.agent_status(pid)) == 0
    end

    test "all agents get role :worker", %{agent_sup: sup, dir: dir} do
      pid = start_conductor("init-roles", [dir], agent_sup: sup)
      :timer.sleep(100)

      assert Enum.all?(Conductor.agent_status(pid), fn {_, info} -> info.role == :worker end)
    end

    test "subscribe delivers :conductor_output events", %{agent_sup: sup, dir: dir} do
      pid = start_conductor("init-sub", [dir], agent_sup: sup)
      :ok = Conductor.subscribe(pid)
      :timer.sleep(100)

      Conductor.broadcast(pid, "hello")

      assert_receive {:conductor_output, "init-sub", _agent_id, data}, 1_000
      assert String.contains?(data, "hello")
    end

    test "subscribe delivers :conductor_agent_ready when agent goes idle", %{agent_sup: sup, dir: dir} do
      pid = start_conductor("init-ready", [dir], agent_sup: sup)
      :ok = Conductor.subscribe(pid)
      :timer.sleep(100)

      Conductor.broadcast(pid, "READY")

      assert_receive {:conductor_agent_ready, "init-ready", _agent_id}, 1_000
    end

    test "broadcast sends to every agent", %{agent_sup: sup, dir: dir} do
      dir2 = System.tmp_dir!()
      pid = start_conductor("init-broadcast", [dir, dir2], agent_sup: sup)
      :ok = Conductor.subscribe(pid)
      :timer.sleep(100)

      Conductor.broadcast(pid, "ping-all")

      agent_ids =
        for _ <- 1..2 do
          assert_receive {:conductor_output, "init-broadcast", agent_id, data}, 1_000
          assert String.contains?(data, "ping-all")
          agent_id
        end

      assert length(Enum.uniq(agent_ids)) == 2
    end

    test "send_to routes only to the named agent", %{agent_sup: sup, dir: dir} do
      dir2 = System.tmp_dir!()
      pid = start_conductor("init-sendto", [dir, dir2], agent_sup: sup)
      :ok = Conductor.subscribe(pid)
      :timer.sleep(100)

      [target_id | _] = pid |> Conductor.agent_status() |> Map.keys()
      Conductor.send_to(pid, target_id, "targeted-msg")

      assert_receive {:conductor_output, "init-sendto", ^target_id, data}, 1_000
      assert String.contains?(data, "targeted-msg")

      refute_receive {:conductor_output, "init-sendto", other_id, _}
                     when other_id != target_id,
                     200
    end

    test "send_to unknown agent id is a no-op", %{agent_sup: sup, dir: dir} do
      pid = start_conductor("init-noop", [dir], agent_sup: sup)
      :ok = Conductor.subscribe(pid)

      Conductor.send_to(pid, "bogus-id", "should-not-arrive")

      refute_receive {:conductor_output, _, _, _}, 200
    end

    test "results returns output per agent in chronological order", %{agent_sup: sup, dir: dir} do
      pid = start_conductor("init-results", [dir], agent_sup: sup)
      :ok = Conductor.subscribe(pid)
      :timer.sleep(100)

      Conductor.broadcast(pid, "first")
      assert_receive {:conductor_output, _, _, _}, 1_000

      Conductor.broadcast(pid, "second")
      assert_receive {:conductor_output, _, _, _}, 1_000

      results = Conductor.results(pid)
      assert map_size(results) == 1

      [chunks] = Map.values(results)
      joined = Enum.join(chunks)
      assert String.contains?(joined, "first")
      assert String.contains?(joined, "second")

      {first_pos, _} = :binary.match(joined, "first")
      {second_pos, _} = :binary.match(joined, "second")
      assert first_pos < second_pos
    end

    test "agent_status includes dir and a known status atom", %{agent_sup: sup, dir: dir} do
      pid = start_conductor("init-astatus", [dir], agent_sup: sup)
      :timer.sleep(100)

      [{_id, info}] = pid |> Conductor.agent_status() |> Map.to_list()
      assert info.dir == dir
      assert info.status in [:starting, :running, :idle, :awaiting_input]
    end

    test "crashing sub-agent does not crash the conductor", %{agent_sup: sup, dir: dir} do
      pid = start_conductor("init-crash", [dir], agent_sup: sup)
      :timer.sleep(100)

      [{_id, %{pid: agent_pid}}] = pid |> Conductor.agent_status() |> Map.to_list()
      Process.exit(agent_pid, :kill)

      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    test "subscriber process exit is cleaned up gracefully", %{agent_sup: sup, dir: dir} do
      pid = start_conductor("init-sub-exit", [dir], agent_sup: sup)

      sub = spawn(fn -> receive do: (_ -> :ok) end)
      :ok = Conductor.subscribe(pid, sub)
      Process.exit(sub, :kill)

      :timer.sleep(50)
      assert Process.alive?(pid)
    end
  end

  # ── Orchestrator mode ─────────────────────────────────────────────────────────

  describe "orchestrator mode" do
    test "starts exactly one agent (the orchestrator) in the context dir", %{agent_sup: sup, dir: ctx} do
      pid = start_conductor("init-orch", [ctx], agent_sup: sup, task: "do the thing", context_dir: ctx)
      :timer.sleep(100)

      statuses = Conductor.agent_status(pid)
      assert map_size(statuses) == 1

      [{_id, info}] = Map.to_list(statuses)
      assert info.dir == ctx
      assert info.role == :orchestrator
    end

    test "orchestrator receives a planning prompt containing the task", %{agent_sup: sup, dir: ctx} do
      pid =
        start_conductor("init-prompt-task", [ctx],
          agent_sup: sup,
          task: "build the auth feature",
          context_dir: ctx
        )

      :ok = Conductor.subscribe(pid)

      chunks = collect_chunks(pid, "init-prompt-task", 20, 200)
      assert String.contains?(Enum.join(chunks), "build the auth feature")
    end

    test "planning prompt lists the working directories", %{agent_sup: sup, dir: ctx} do
      dir2 = System.tmp_dir!()

      pid =
        start_conductor("init-prompt-dirs", [ctx, dir2],
          agent_sup: sup,
          task: "check dirs",
          context_dir: ctx
        )

      :ok = Conductor.subscribe(pid)

      combined = pid |> collect_chunks("init-prompt-dirs", 20, 200) |> Enum.join()
      assert String.contains?(combined, ctx)
      assert String.contains?(combined, dir2)
    end

    test "planning prompt contains the adapter name", %{agent_sup: sup, dir: ctx} do
      pid =
        start_conductor("init-prompt-adapter", [ctx],
          agent_sup: sup,
          task: "verify adapter",
          context_dir: ctx
        )

      :ok = Conductor.subscribe(pid)

      combined = pid |> collect_chunks("init-prompt-adapter", 20, 200) |> Enum.join()
      assert String.contains?(combined, "echo")
    end

    test "planning prompt includes orchestration.md content when present", %{agent_sup: sup, dir: ctx} do
      File.write!(Path.join(ctx, "orchestration.md"), "## Goal\n\nShip the rocket.")

      pid =
        start_conductor("init-orch-md", [ctx],
          agent_sup: sup,
          task: "launch",
          context_dir: ctx
        )

      :ok = Conductor.subscribe(pid)

      combined = pid |> collect_chunks("init-orch-md", 20, 200) |> Enum.join()
      assert String.contains?(combined, "Ship the rocket.")
    end

    test "planning prompt works without orchestration.md", %{agent_sup: sup, dir: ctx} do
      pid =
        start_conductor("init-no-orch-md", [ctx],
          agent_sup: sup,
          task: "run without file",
          context_dir: ctx
        )

      :ok = Conductor.subscribe(pid)

      combined = pid |> collect_chunks("init-no-orch-md", 20, 200) |> Enum.join()
      assert String.contains?(combined, "run without file")
    end
  end

  # Drains up to `max` conductor_output chunks for `initiative_id` with `timeout` ms each.
  defp collect_chunks(_pid, initiative_id, max, timeout) do
    Enum.reduce_while(1..max, [], fn _, acc ->
      receive do
        {:conductor_output, ^initiative_id, _, data} -> {:cont, [data | acc]}
      after
        timeout -> {:halt, acc}
      end
    end)
    |> Enum.reverse()
  end
end

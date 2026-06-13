defmodule Codrift.ConductorSupervisorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.{AgentSupervisor, ConductorSupervisor, Initiative}
  alias Codrift.Test.EchoAdapter

  setup do
    agent_sup = start_supervised!({AgentSupervisor, name: nil})
    conductor_sup = start_supervised!({ConductorSupervisor, name: nil})
    reg_name = :"conductor-reg-#{:erlang.unique_integer([:positive])}"
    registry = start_supervised!({Registry, keys: :unique, name: reg_name})

    dir = System.tmp_dir!()
    initiative = Initiative.new("test-#{:erlang.unique_integer([:positive])}", [dir])

    %{
      agent_sup: agent_sup,
      conductor_sup: conductor_sup,
      registry: registry,
      reg_name: reg_name,
      dir: dir,
      initiative: initiative
    }
  end

  defp start(initiative, opts) do
    ConductorSupervisor.start_conductor(initiative, EchoAdapter, opts)
  end

  defp start_orch(initiative, task, opts) do
    ConductorSupervisor.start_orchestration(initiative, EchoAdapter, task, opts)
  end

  # ── start_conductor ───────────────────────────────────────────────────────────

  test "start_conductor returns {:ok, pid}",
       %{conductor_sup: csup, agent_sup: asup, reg_name: reg, initiative: i} do
    assert {:ok, pid} = start(i, server: csup, agent_supervisor: asup, conductor_registry: reg)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "list_conductors returns the started pid",
       %{conductor_sup: csup, agent_sup: asup, reg_name: reg, initiative: i} do
    {:ok, pid} = start(i, server: csup, agent_supervisor: asup, conductor_registry: reg)
    assert pid in ConductorSupervisor.list_conductors(csup)
  end

  test "find_conductor locates conductor by initiative_id",
       %{conductor_sup: csup, agent_sup: asup, reg_name: reg, initiative: i} do
    {:ok, pid} = start(i, server: csup, agent_supervisor: asup, conductor_registry: reg)
    assert {:ok, ^pid} = ConductorSupervisor.find_conductor(i.id, reg)
  end

  test "find_conductor returns {:error, :not_found} when nothing started",
       %{reg_name: reg} do
    assert {:error, :not_found} = ConductorSupervisor.find_conductor("no-such-id", reg)
  end

  test "stop_conductor terminates the conductor process",
       %{conductor_sup: csup, agent_sup: asup, reg_name: reg, initiative: i} do
    {:ok, pid} = start(i, server: csup, agent_supervisor: asup, conductor_registry: reg)
    assert pid in ConductorSupervisor.list_conductors(csup)

    :ok = ConductorSupervisor.stop_conductor(i.id, server: csup, registry: reg)

    :timer.sleep(50)
    refute pid in ConductorSupervisor.list_conductors(csup)
    refute Process.alive?(pid)
  end

  test "stop_conductor on unknown id is a no-op",
       %{conductor_sup: csup, reg_name: reg} do
    assert :ok = ConductorSupervisor.stop_conductor("no-such-id", server: csup, registry: reg)
  end

  test "list_conductors returns multiple running conductors",
       %{conductor_sup: csup, agent_sup: asup, reg_name: reg, dir: dir} do
    i1 = Initiative.new("multi-a-#{:erlang.unique_integer([:positive])}", [dir])
    i2 = Initiative.new("multi-b-#{:erlang.unique_integer([:positive])}", [dir])

    {:ok, pid1} = start(i1, server: csup, agent_supervisor: asup, conductor_registry: reg)
    {:ok, pid2} = start(i2, server: csup, agent_supervisor: asup, conductor_registry: reg)

    conductors = ConductorSupervisor.list_conductors(csup)
    assert pid1 in conductors
    assert pid2 in conductors
  end

  test "crashing conductor does not crash the supervisor",
       %{conductor_sup: csup, agent_sup: asup, reg_name: reg, initiative: i} do
    {:ok, pid} = start(i, server: csup, agent_supervisor: asup, conductor_registry: reg)

    Process.exit(pid, :kill)
    :timer.sleep(50)

    refute Process.alive?(pid)
    assert Process.alive?(csup)
  end

  # ── start_orchestration ───────────────────────────────────────────────────────

  test "start_orchestration returns {:ok, pid}",
       %{conductor_sup: csup, agent_sup: asup, reg_name: reg, dir: dir, initiative: i} do
    assert {:ok, pid} =
             start_orch(i, "build feature",
               server: csup,
               agent_supervisor: asup,
               conductor_registry: reg,
               context_dir: dir
             )

    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "start_orchestration starts exactly one orchestrator agent",
       %{conductor_sup: csup, agent_sup: asup, reg_name: reg, dir: dir, initiative: i} do
    {:ok, pid} =
      start_orch(i, "check everything",
        server: csup,
        agent_supervisor: asup,
        conductor_registry: reg,
        context_dir: dir
      )

    :timer.sleep(100)
    statuses = Codrift.Conductor.agent_status(pid)
    assert map_size(statuses) == 1
    assert Enum.all?(statuses, fn {_, info} -> info.role == :orchestrator end)
  end

  test "conductors for different initiatives coexist",
       %{conductor_sup: csup, agent_sup: asup, reg_name: reg, dir: dir} do
    i1 = Initiative.new("coex-a-#{:erlang.unique_integer([:positive])}", [dir])
    i2 = Initiative.new("coex-b-#{:erlang.unique_integer([:positive])}", [dir])

    {:ok, pid1} = start(i1, server: csup, agent_supervisor: asup, conductor_registry: reg)
    {:ok, pid2} = start(i2, server: csup, agent_supervisor: asup, conductor_registry: reg)

    assert pid1 != pid2
    assert Process.alive?(pid1)
    assert Process.alive?(pid2)
    assert {:ok, ^pid1} = ConductorSupervisor.find_conductor(i1.id, reg)
    assert {:ok, ^pid2} = ConductorSupervisor.find_conductor(i2.id, reg)
  end
end

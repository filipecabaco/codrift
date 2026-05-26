defmodule Codrift.AgentSupervisorTest do
  use ExUnit.Case, async: true

  alias Codrift.AgentSupervisor
  alias Codrift.AgentProcess
  alias Codrift.Test.EchoAdapter

  setup do
    sup = start_supervised!({AgentSupervisor, name: nil})
    %{sup: sup}
  end

  test "starts with no agents", %{sup: sup} do
    assert [] = AgentSupervisor.list_agents(sup)
  end

  test "start_agent returns {:ok, pid}", %{sup: sup} do
    assert {:ok, pid} =
             AgentSupervisor.start_agent("init-1", System.tmp_dir!(), EchoAdapter, server: sup)

    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "list_agents returns running agent pids", %{sup: sup} do
    {:ok, pid1} =
      AgentSupervisor.start_agent("init-1", System.tmp_dir!(), EchoAdapter, server: sup)

    {:ok, pid2} =
      AgentSupervisor.start_agent("init-1", System.tmp_dir!(), EchoAdapter, server: sup)

    agents = AgentSupervisor.list_agents(sup)
    assert pid1 in agents
    assert pid2 in agents
  end

  test "stop_agent removes agent from list", %{sup: sup} do
    {:ok, pid} =
      AgentSupervisor.start_agent("init-1", System.tmp_dir!(), EchoAdapter, server: sup)

    assert pid in AgentSupervisor.list_agents(sup)

    :ok = AgentSupervisor.stop_agent(pid, sup)
    refute pid in AgentSupervisor.list_agents(sup)
  end

  test "crashing agent does not crash supervisor", %{sup: sup} do
    {:ok, pid} =
      AgentSupervisor.start_agent("init-1", System.tmp_dir!(), EchoAdapter, server: sup)

    Process.exit(pid, :kill)
    :timer.sleep(50)

    refute Process.alive?(pid)
    assert Process.alive?(sup)
  end

  test "each agent gets a unique id", %{sup: sup} do
    {:ok, pid1} =
      AgentSupervisor.start_agent("init-1", System.tmp_dir!(), EchoAdapter, server: sup)

    {:ok, pid2} =
      AgentSupervisor.start_agent("init-1", System.tmp_dir!(), EchoAdapter, server: sup)

    %{id: id1} = AgentProcess.status(pid1)
    %{id: id2} = AgentProcess.status(pid2)

    refute id1 == id2
  end

  test "agents for different initiatives can coexist", %{sup: sup} do
    {:ok, pid1} =
      AgentSupervisor.start_agent("init-a", System.tmp_dir!(), EchoAdapter, server: sup)

    {:ok, pid2} =
      AgentSupervisor.start_agent("init-b", System.tmp_dir!(), EchoAdapter, server: sup)

    assert %{initiative_id: "init-a"} = AgentProcess.status(pid1)
    assert %{initiative_id: "init-b"} = AgentProcess.status(pid2)
  end
end

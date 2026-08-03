defmodule Codrift.Web.EventRelayTest do
  use ExUnit.Case, async: true

  alias Codrift.AgentSupervisor
  alias Codrift.Test.EchoAdapter
  alias Codrift.Web.EventRelay

  describe "frame/1" do
    test "encodes agent output as base64 so binary PTY bytes survive JSON" do
      assert %{event: "output", agent_id: "a1", content: content} =
               EventRelay.frame({:agent_output, "a1", <<0xC3, 0x28, "hi">>})

      assert Base.decode64!(content) == <<0xC3, 0x28, "hi">>
    end

    test "stringifies status atoms" do
      assert %{event: "status", agent_id: "a1", status: "awaiting_input"} =
               EventRelay.frame({:agent_status, "a1", :awaiting_input})
    end

    test "carries the exit code on stop" do
      assert %{event: "stopped", agent_id: "a1", exit_code: 137} =
               EventRelay.frame({:agent_stopped, "a1", 137})
    end

    test "covers the conductor events" do
      assert %{event: "conductor_output", initiative_id: "i1", agent_id: "a1"} =
               EventRelay.frame({:conductor_output, "i1", "a1", "x"})

      assert %{event: "conductor_agent_ready", initiative_id: "i1", agent_id: "a1"} =
               EventRelay.frame({:conductor_agent_ready, "i1", "a1"})

      assert %{event: "conductor_agent_stopped", exit_code: 0} =
               EventRelay.frame({:conductor_agent_stopped, "i1", "a1", 0})
    end

    # format_response/2 raises on unknown shapes, so dropping them here is what
    # keeps a stray message from killing the connection.
    test "announces a started agent with its full descriptor" do
      agent = %{id: "a1", adapter: "terminal", status: "starting", dir: "/tmp", mode: "pty"}

      assert %{event: "agent_started", agent_id: "a1", agent: ^agent} =
               EventRelay.frame({:agent_started, agent})
    end

    test "drops messages the client has no use for" do
      assert EventRelay.frame({:agent_ready, "a1"}) == nil
      assert EventRelay.frame(:some_unrelated_message) == nil
      assert EventRelay.frame({:unexpected, 1, 2, 3, 4}) == nil
    end

    test "every frame is JSON-encodable" do
      for msg <- [
            {:agent_output, "a1", <<0xFF>>},
            {:agent_status, "a1", :running},
            {:agent_stopped, "a1", 1},
            {:conductor_output, "i1", "a1", <<0xFF>>},
            {:conductor_agent_ready, "i1", "a1"},
            {:conductor_agent_stopped, "i1", "a1", 2}
          ] do
        assert {:ok, _} = msg |> EventRelay.frame() |> Jason.encode()
      end
    end
  end

  describe "describe/1" do
    setup do
      sup = start_supervised!({AgentSupervisor, name: nil})
      %{sup: sup}
    end

    test "renders an agent in the same shape list_agents returns", %{sup: sup} do
      initiative = "snap-#{System.unique_integer([:positive])}"

      {:ok, agent} =
        AgentSupervisor.start_agent(initiative, System.tmp_dir!(), EchoAdapter, server: sup)

      described = EventRelay.describe(agent)

      assert %{initiative_id: ^initiative, adapter: adapter, status: status} = described
      assert is_binary(adapter)
      assert is_binary(status)
      assert {:ok, _} = Jason.encode(described)
    end
  end

  describe "relay process" do
    setup do
      sup = start_supervised!({AgentSupervisor, name: nil})
      %{sup: sup}
    end

    test "forwards an agent's output to the socket as a frame", %{sup: sup} do
      initiative = "relay-#{System.unique_integer([:positive])}"
      socket = self()

      {:ok, relay} = EventRelay.start_link(socket)
      Process.unlink(relay)

      {:ok, agent} =
        AgentSupervisor.start_agent(initiative, System.tmp_dir!(), EchoAdapter, server: sup)

      %{id: agent_id} = Codrift.AgentProcess.status(agent)
      Codrift.AgentProcess.send_input(agent, "ping\n")

      assert_receive %{event: "output", agent_id: ^agent_id, content: content}, 2_000
      assert Base.decode64!(content) =~ "ping"
    end

    test "dies with its socket", %{sup: _sup} do
      socket =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, relay} = EventRelay.start_link(socket)
      Process.unlink(relay)
      ref = Process.monitor(relay)

      send(socket, :stop)

      assert_receive {:DOWN, ^ref, :process, ^relay, _}, 2_000
    end
  end
end

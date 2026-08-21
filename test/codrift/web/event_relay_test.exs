defmodule Codrift.Web.EventRelayTest do
  use ExUnit.Case, async: true

  alias Codrift.AgentSupervisor
  alias Codrift.Test.EchoAdapter
  alias Codrift.Web.EventRelay

  describe "frame/1 — initiative lifecycle" do
    # The client patches its state straight from this payload, so it has to be
    # the same shape `list_initiatives` returns — including `context_path`,
    # which `Initiative.to_map/1` alone does not carry.
    test "created and updated carry the API-boundary initiative map" do
      initiative = Codrift.Initiative.new("Fresh")
      id = initiative.id

      assert %{event: "initiative_created", initiative: created} =
               EventRelay.frame({:initiative_created, initiative})

      assert %{"id" => ^id, "name" => "Fresh", "context_path" => path} = created
      assert is_binary(path)

      assert %{event: "initiative_updated", initiative: %{"id" => ^id}} =
               EventRelay.frame({:initiative_updated, initiative})
    end

    test "deleted carries only the id, since the record is gone" do
      assert %{event: "initiative_deleted", initiative_id: "i1"} =
               EventRelay.frame({:initiative_deleted, "i1"})
    end

    # Deliberately says only *that* memory moved: the memory view owns a query
    # string no frame could reproduce, so re-running it is the only refresh.
    test "memory_changed names the initiative and nothing else" do
      assert %{event: "memory_changed", initiative_id: "i1"} =
               EventRelay.frame({:memory_changed, "i1"})
    end
  end

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

    # Not a notification like the rest: an agent asking the window to put a pane
    # in front of the user, because it has hit a step only a human can take.
    test "carries a pane request with its initiative, agent and reason" do
      assert %{
               event: "pane_request",
               initiative_id: "i1",
               agent_id: "a1",
               reason: "review and commit"
             } = EventRelay.frame({:pane_request, "i1", "a1", "review and commit"})
    end

    test "a pane request without a reason still frames" do
      assert %{event: "pane_request", reason: nil} =
               EventRelay.frame({:pane_request, "i1", "a1", nil})
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
            {:conductor_agent_stopped, "i1", "a1", 2},
            {:pane_request, "i1", "a1", "review and commit"},
            {:pane_request, "i1", "a1", nil}
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

  describe "broadcast/1" do
    # Agent lifecycle events reach a window because AgentSupervisor wires each
    # new agent to the watchers. A pane request has no lifecycle to hang off —
    # nothing about the agent changed — so it goes through this door instead.
    test "reaches every connected window as a client frame" do
      {:ok, relay} = EventRelay.start_link(self())
      Process.unlink(relay)

      EventRelay.broadcast({:pane_request, "i-broadcast", "a-broadcast", "come here"})

      assert_receive %{
                       event: "pane_request",
                       initiative_id: "i-broadcast",
                       agent_id: "a-broadcast",
                       reason: "come here"
                     },
                     2_000
    end

    # frame/1 drops what it does not recognise, so an event nobody has taught the
    # client about is inert rather than fatal to the socket. Proven by sending a
    # good event *after* the bad one and seeing it arrive: a bare refute on the
    # mailbox would only prove that no OTHER test happened to broadcast, since
    # every relay is registered against the same global watcher registry.
    test "an unroutable event leaves the relay working" do
      {:ok, relay} = EventRelay.start_link(self())
      Process.unlink(relay)

      EventRelay.broadcast({:definitely_not_a_frame, 1, 2})
      EventRelay.broadcast({:pane_request, "i-after-junk", "a-after-junk", nil})

      assert_receive %{event: "pane_request", initiative_id: "i-after-junk"}, 2_000
      assert Process.alive?(relay)
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

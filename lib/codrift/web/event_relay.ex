defmodule Codrift.Web.EventRelay do
  @moduledoc """
  Bridges Codrift's internal event tuples onto the client WebSocket.

  Agents and conductors broadcast plain tuples, and the Conductor consumes those
  tuples from the agents it manages, so producers can't emit socket-shaped
  payloads instead. Francis passes whatever the socket receives to
  `format_response/2`, which raises on a bare tuple — hence a relay per
  connection, subscribed on the socket's behalf. Frames are keyed by `agent_id`.

      %{event: "agent_started", agent_id: id, agent: %{…, initiative_id: iid}}
      %{event: "output",   agent_id: id, content: base64}
      %{event: "status",   agent_id: id, status: "awaiting_input"}
      %{event: "stopped",  agent_id: id, exit_code: 0}
      %{event: "conductor_output", initiative_id: iid, agent_id: id, content: base64}
      %{event: "conductor_agent_ready",   initiative_id: iid, agent_id: id}
      %{event: "conductor_agent_stopped", initiative_id: iid, agent_id: id, exit_code: 0}
  """

  use GenServer

  alias Codrift.{AgentProcess, AgentSupervisor, Conductor, ConductorSupervisor}

  @doc """
  Starts a relay forwarding frames to `socket`.

  Subscribes to every running agent and conductor, and registers in
  `Codrift.AgentWatchers` so agents started later reach it too.
  """
  def start_link(socket \\ self()) do
    GenServer.start_link(__MODULE__, socket)
  end

  @doc """
  Every running agent, in the shape `list_agents` returns.

  Sent with the join reply, so a transition that happened before the socket
  connected isn't lost.
  """
  def snapshot do
    Enum.map(AgentSupervisor.list_agents(), &describe/1)
  end

  @doc "Agent status map with the adapter and status rendered as strings."
  def describe(pid) do
    pid
    |> AgentProcess.status()
    |> Map.update!(:adapter, &Codrift.Agent.adapter_name/1)
    |> Map.update!(:status, &to_string/1)
  end

  @impl true
  def init(socket) do
    # Link so a relay crash drops the socket; monitor because a normal socket
    # exit doesn't propagate over a link.
    Process.link(socket)
    Process.monitor(socket)

    Enum.each(AgentSupervisor.list_agents(), &AgentProcess.subscribe(&1, self()))
    Enum.each(ConductorSupervisor.list_conductors(), &Conductor.subscribe(&1, self()))

    Registry.register(Codrift.AgentWatchers, :all, nil)

    {:ok, %{socket: socket}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, socket, _reason}, %{socket: socket} = state) do
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    case frame(msg) do
      nil -> {:noreply, state}
      frame -> {:noreply, tap(state, &send(&1.socket, frame))}
    end
  end

  @doc """
  Translates an internal event tuple into a client frame, or `nil` for events the
  client has no use for (dropped rather than crashing the socket).
  """
  def frame({:agent_started, agent}),
    do: %{event: "agent_started", agent_id: agent.id, agent: agent}

  def frame({:agent_output, agent_id, data}),
    do: %{event: "output", agent_id: agent_id, content: Base.encode64(data)}

  def frame({:agent_status, agent_id, status}),
    do: %{event: "status", agent_id: agent_id, status: to_string(status)}

  def frame({:agent_stopped, agent_id, code}),
    do: %{event: "stopped", agent_id: agent_id, exit_code: code}

  def frame({:conductor_output, initiative_id, agent_id, data}),
    do: %{
      event: "conductor_output",
      initiative_id: initiative_id,
      agent_id: agent_id,
      content: Base.encode64(data)
    }

  def frame({:conductor_agent_ready, initiative_id, agent_id}),
    do: %{event: "conductor_agent_ready", initiative_id: initiative_id, agent_id: agent_id}

  def frame({:conductor_agent_stopped, initiative_id, agent_id, code}),
    do: %{
      event: "conductor_agent_stopped",
      initiative_id: initiative_id,
      agent_id: agent_id,
      exit_code: code
    }

  def frame(_other), do: nil
end

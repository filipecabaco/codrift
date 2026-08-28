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
      %{event: "pane_request", initiative_id: iid, agent_id: id, reason: "…"}

  Initiative and memory frames are not keyed by `agent_id` — they carry the
  changed record (or just the initiative id) so a client can patch one row:

      %{event: "initiative_created", initiative: %{"id" => iid, …}}
      %{event: "initiative_updated", initiative: %{"id" => iid, …}}
      %{event: "initiative_deleted", initiative_id: iid}
      %{event: "memory_changed", initiative_id: iid}
  """

  use GenServer

  alias Codrift.{AgentProcess, AgentSupervisor, Conductor, ConductorSupervisor, Core}

  @doc """
  Starts a relay forwarding frames to `socket`.

  Subscribes to every running agent and conductor, and registers in
  `Codrift.AgentWatchers` so agents started later reach it too.
  """
  def start_link(socket \\ self()) do
    GenServer.start_link(__MODULE__, socket)
  end

  @doc """
  Pushes an event tuple to every connected window.

  `AgentSupervisor` wires each new agent to the watchers on its own, which
  covers everything keyed to an agent's lifecycle. This is the door for events
  that aren't: a tool asking the UI to *do* something — surface a pane, move the
  keyboard — where there is no state change to infer it from. Unroutable events
  are dropped by `frame/1`, so a new tuple can't take a socket down.
  """
  def broadcast(event) do
    Registry.dispatch(Codrift.AgentWatchers, :all, fn watchers ->
      Enum.each(watchers, fn {watcher, _} -> send(watcher, event) end)
    end)
  rescue
    # No registry (tests, CLI-only runs) simply means nobody is watching.
    ArgumentError -> :ok
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
    |> Map.update!(:role, &to_string/1)
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

  # Not a state change, but a request: an agent asking the window to put this
  # agent in front of the user because it needs a human at the keyboard.
  def frame({:pane_request, initiative_id, agent_id, reason}),
    do: %{
      event: "pane_request",
      initiative_id: initiative_id,
      agent_id: agent_id,
      reason: reason
    }

  # The same shape of request for a *file*: an agent has pinned something worth
  # looking at into the initiative's context folder and is asking the window to
  # open it. Carries the link name rather than the source path because that is
  # what the Context pane addresses files by.
  def frame({:file_request, initiative_id, name, reason}),
    do: %{
      event: "file_request",
      initiative_id: initiative_id,
      name: name,
      reason: reason
    }

  # ── Initiative lifecycle ────────────────────────────────────────────────────
  #
  # The open window is not the only writer of the initiative list: `codrift
  # initiative create` from a shell, an MCP-connected agent, and a second window
  # all mutate it behind this session's back, and until these frames existed the
  # change was invisible until a manual reload.
  #
  # The frame carries the whole record rather than just the id so the client can
  # patch the row it names. Re-running the client's `load()` instead would cost
  # an N+1 of `get_initiative_agents` per initiative on every rename.
  #
  # `Core.initiative_map/1` — not `Initiative.to_map/1` — because the client's
  # `Initiative` type includes fields derived at the API boundary (`context_path`,
  # per-dir `git`). Patching with the leaner shape would silently strip them from
  # whichever row changed. It stats the filesystem, so it runs here, per socket,
  # rather than inside the store's GenServer on every write.

  def frame({:initiative_created, initiative}),
    do: %{event: "initiative_created", initiative: Core.initiative_map(initiative)}

  def frame({:initiative_updated, initiative}),
    do: %{event: "initiative_updated", initiative: Core.initiative_map(initiative)}

  def frame({:initiative_deleted, initiative_id}),
    do: %{event: "initiative_deleted", initiative_id: initiative_id}

  # Deliberately says only *that* memory changed, never what. The memory view
  # owns a query string this frame cannot reproduce, so the only correct refresh
  # is the view re-running its own query.
  def frame({:memory_changed, initiative_id}),
    do: %{event: "memory_changed", initiative_id: initiative_id}

  def frame(_other), do: nil
end

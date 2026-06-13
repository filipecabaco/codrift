defmodule Codrift.Conductor do
  @moduledoc """
  Orchestrates multiple AgentProcess instances under a single initiative.

  One Conductor per initiative. It auto-starts one agent per directory when
  launched, subscribes to every sub-agent's output stream, and re-broadcasts
  those events to any interested subscriber (TUI, SSE handler, tests).

  ## Lifecycle

      {:ok, pid} = ConductorSupervisor.start_conductor(initiative, adapter)

      # Send a prompt to every sub-agent
      Conductor.broadcast(pid, "run the test suite and report failures")

      # Send a prompt to one sub-agent
      Conductor.send_to(pid, agent_id, "focus on lib/auth only")

      # Collect what all agents have produced
      Conductor.results(pid)
      # => %{"<agent_id>" => ["chunk", ...], ...}

  ## Messages delivered to subscribers

      {:conductor_output,        initiative_id, agent_id, chunk}
      {:conductor_agent_ready,   initiative_id, agent_id}
      {:conductor_agent_stopped, initiative_id, agent_id, exit_code}
  """

  use GenServer
  require Logger

  alias Codrift.{AgentProcess, AgentSupervisor}
  alias Codrift.Initiative.DirEntry

  @max_chunks 500

  defstruct [
    :initiative_id,
    :adapter,
    agents: %{},
    results: %{},
    subscribers: %{}
  ]

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :initiative_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc """
  Starts a Conductor.

  Required opts: `:initiative_id`, `:dirs` (list of absolute paths), `:adapter`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Sends `text` to every running sub-agent."
  def broadcast(pid, text), do: GenServer.cast(pid, {:broadcast, text})

  @doc "Sends `text` to the sub-agent identified by `agent_id`."
  def send_to(pid, agent_id, text), do: GenServer.cast(pid, {:send_to, agent_id, text})

  @doc "Returns aggregated output per agent in chronological order."
  def results(pid), do: GenServer.call(pid, :results)

  @doc "Returns `%{agent_id => %{dir, status}}` for all sub-agents."
  def agent_status(pid), do: GenServer.call(pid, :agent_status)

  @doc "Subscribes `subscriber` (default: `self()`) to conductor-level events."
  def subscribe(pid, subscriber \\ self()), do: GenServer.call(pid, {:subscribe, subscriber})

  # ── Server ───────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    initiative_id = Keyword.fetch!(opts, :initiative_id)
    dirs = Keyword.fetch!(opts, :dirs)
    adapter = Keyword.fetch!(opts, :adapter)

    if Process.whereis(Codrift.ConductorRegistry) do
      Registry.register(Codrift.ConductorRegistry, initiative_id, %{})
    end

    state = %__MODULE__{initiative_id: initiative_id, adapter: adapter}

    {:ok, state, {:continue, {:start_agents, dirs}}}
  end

  @impl true
  def handle_continue({:start_agents, dirs}, state) do
    agents =
      Enum.reduce(dirs, %{}, fn dir, acc ->
        case AgentSupervisor.start_agent(state.initiative_id, dir, state.adapter) do
          {:ok, pid} ->
            AgentProcess.subscribe(pid)
            %{id: id} = AgentProcess.status(pid)
            Map.put(acc, id, %{pid: pid, dir: dir, status: :starting})

          {:error, reason} ->
            Logger.error("[Conductor #{state.initiative_id}] failed to start agent for #{dir}: #{inspect(reason)}")
            acc
        end
      end)

    {:noreply, %{state | agents: agents}}
  end

  @impl true
  def handle_cast({:broadcast, text}, state) do
    for {_id, %{pid: pid}} <- state.agents, do: AgentProcess.send_input(pid, text)
    {:noreply, state}
  end

  def handle_cast({:send_to, agent_id, text}, state) do
    case Map.get(state.agents, agent_id) do
      %{pid: pid} ->
        AgentProcess.send_input(pid, text)

      nil ->
        Logger.warning("[Conductor #{state.initiative_id}] send_to unknown agent #{agent_id}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:results, _from, state) do
    out = Map.new(state.results, fn {id, chunks} -> {id, Enum.reverse(chunks)} end)
    {:reply, out, state}
  end

  def handle_call(:agent_status, _from, state) do
    summary = Map.new(state.agents, fn {id, info} -> {id, %{dir: info.dir, status: info.status}} end)
    {:reply, summary, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    subs =
      if Map.has_key?(state.subscribers, pid) do
        state.subscribers
      else
        ref = Process.monitor(pid)
        Map.put(state.subscribers, pid, ref)
      end

    {:reply, :ok, %{state | subscribers: subs}}
  end

  @impl true
  def handle_info({:agent_output, id, data}, state) do
    results =
      Map.update(state.results, id, [data], fn prev ->
        if length(prev) >= @max_chunks,
          do: [data | Enum.take(prev, @max_chunks - 1)],
          else: [data | prev]
      end)

    agents = Map.update(state.agents, id, %{status: :running}, &%{&1 | status: :running})
    notify(state, {:conductor_output, state.initiative_id, id, data})
    {:noreply, %{state | results: results, agents: agents}}
  end

  def handle_info({:agent_ready, id}, state) do
    agents = Map.update(state.agents, id, %{status: :idle}, &%{&1 | status: :idle})
    notify(state, {:conductor_agent_ready, state.initiative_id, id})
    {:noreply, %{state | agents: agents}}
  end

  def handle_info({:agent_stopped, id, code}, state) do
    Logger.info("[Conductor #{state.initiative_id}] agent #{id} stopped (code #{code})")
    agents = Map.update(state.agents, id, %{status: :stopped}, &%{&1 | status: :stopped})
    notify(state, {:conductor_agent_stopped, state.initiative_id, id, code})
    {:noreply, %{state | agents: agents}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp notify(%{subscribers: subs}, msg) do
    for {pid, _} <- subs, do: send(pid, msg)
  end
end

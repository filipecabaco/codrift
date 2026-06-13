defmodule Codrift.Conductor do
  @moduledoc """
  Orchestrates multiple AgentProcess instances under a single initiative.

  ## Two modes

  ### Fan-out mode (direct)
  Started via `ConductorSupervisor.start_conductor/3`. Auto-starts one agent
  per directory, subscribers receive output from all of them.

      {:ok, pid} = ConductorSupervisor.start_conductor(initiative, adapter)
      Conductor.broadcast(pid, "run the test suite and report failures")
      Conductor.results(pid)

  ### Orchestrator mode
  Started via `ConductorSupervisor.start_orchestration/3`. Starts ONE Claude
  agent in the initiative's context directory and hands it a planning prompt.
  That agent uses the Codrift MCP tools (`start_agent`, `send_to_agent`,
  `get_agent_output`, `broadcast_to_initiative`, `memory_*`) to reason about,
  start, and direct sub-agents itself — no Elixir-level reasoning loop needed.

      {:ok, pid} = ConductorSupervisor.start_orchestration(initiative, adapter, task)

  ## Messages delivered to subscribers

      {:conductor_output,        initiative_id, agent_id, chunk}
      {:conductor_agent_ready,   initiative_id, agent_id}
      {:conductor_agent_stopped, initiative_id, agent_id, exit_code}
  """

  use GenServer
  require Logger

  alias Codrift.{AgentProcess, AgentSupervisor}
  alias Codrift.Initiative.{DirEntry, Store}

  @max_chunks 500

  defstruct [
    :initiative_id,
    :adapter,
    :orchestrator_id,
    :context_dir,
    :agent_supervisor,
    :conductor_registry,
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

  Required opts: `:initiative_id`, `:dirs`, `:adapter`.
  Optional:
  - `:task` — activates orchestrator mode
  - `:context_dir` — overrides `Store.context_path/1` (useful in tests)
  - `:agent_supervisor` — overrides `AgentSupervisor` server (useful in tests)
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
    task = Keyword.get(opts, :task)
    context_dir = Keyword.get(opts, :context_dir)
    agent_supervisor = Keyword.get(opts, :agent_supervisor, Codrift.AgentSupervisor)
    conductor_registry = Keyword.get(opts, :conductor_registry, Codrift.ConductorRegistry)

    if Process.whereis(conductor_registry) do
      Registry.register(conductor_registry, initiative_id, %{})
    end

    state = %__MODULE__{
      initiative_id: initiative_id,
      adapter: adapter,
      context_dir: context_dir,
      agent_supervisor: agent_supervisor,
      conductor_registry: conductor_registry
    }

    continue =
      if task,
        do: {:start_orchestrator, dirs, task},
        else: {:start_agents, dirs}

    {:ok, state, {:continue, continue}}
  end

  # Fan-out mode: one agent per directory, started immediately.
  @impl true
  def handle_continue({:start_agents, dirs}, state) do
    agents = start_agents_for_dirs(state.initiative_id, state.adapter, dirs, state.agent_supervisor)
    {:noreply, %{state | agents: agents}}
  end

  # Orchestrator mode: start one agent in the context dir and give it a
  # planning prompt. It will use MCP tools to start and direct sub-agents.
  def handle_continue({:start_orchestrator, dirs, task}, state) do
    ctx_dir = state.context_dir || Store.context_path(state.initiative_id)

    case AgentSupervisor.start_agent(state.initiative_id, ctx_dir, state.adapter,
           server: state.agent_supervisor
         ) do
      {:ok, pid} ->
        AgentProcess.subscribe(pid)
        %{id: id} = AgentProcess.status(pid)

        agents = %{id => %{pid: pid, dir: ctx_dir, status: :starting, role: :orchestrator}}

        adapter_name = Codrift.Agent.adapter_name(state.adapter)
        prompt = orchestrator_prompt(state.initiative_id, dirs, task, adapter_name)
        AgentProcess.send_input(pid, prompt)

        {:noreply, %{state | agents: agents, orchestrator_id: id}}

      {:error, reason} ->
        Logger.error("[Conductor #{state.initiative_id}] failed to start orchestrator: #{inspect(reason)}")
        {:noreply, state}
    end
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
    summary =
      Map.new(state.agents, fn {id, info} ->
        {id, %{dir: info.dir, status: info.status, role: Map.get(info, :role, :worker)}}
      end)

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

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp start_agents_for_dirs(initiative_id, adapter, dirs, agent_supervisor) do
    Enum.reduce(dirs, %{}, fn dir, acc ->
      case AgentSupervisor.start_agent(initiative_id, dir, adapter, server: agent_supervisor) do
        {:ok, pid} ->
          AgentProcess.subscribe(pid)
          %{id: id} = AgentProcess.status(pid)
          Map.put(acc, id, %{pid: pid, dir: dir, status: :starting, role: :worker})

        {:error, reason} ->
          Logger.error("[Conductor #{initiative_id}] failed to start agent for #{dir}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp notify(%{subscribers: subs}, msg) do
    for {pid, _} <- subs, do: send(pid, msg)
  end

  defp orchestrator_prompt(initiative_id, dirs, task, adapter_name) do
    dir_list = Enum.map_join(dirs, "\n", &"  - #{&1}")

    """
    You are the orchestrator for initiative `#{initiative_id}`.

    ## Task
    #{task}

    ## Working directories
    #{dir_list}

    ## Your job
    Use the Codrift MCP tools to coordinate this work across the directories above:

    1. **Plan** — decide what each directory's agent should do based on the task and the initiative context in this folder.
    2. **Start agents** — call `start_agent` for each directory with adapter `#{adapter_name}`.
    3. **Assign work** — call `send_to_agent` with a focused, specific prompt for each agent. Each agent only knows about its own directory; give it clear instructions.
    4. **Monitor** — poll `get_agent_output` to track progress. Use `get_initiative_agents` to see which agents are still running.
    5. **Coordinate** — use `memory_search` before dispatching to avoid duplicating decisions already made. Use `memory_add` (type: decision) to record choices that affect multiple agents.
    6. **Synthesise** — once all agents are idle or stopped, read their output, reconcile any conflicts, and write a `summary` to `memory_add` describing what was accomplished.

    Call `broadcast_to_initiative` when all agents need the same message (e.g. "run tests and report results").

    Begin now.
    """
  end
end

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
  alias Codrift.Initiative.Store

  @max_chunks 500

  defstruct [
    :initiative_id,
    :adapter,
    :orchestrator_id,
    :context_dir,
    :agent_supervisor,
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
  - `:conductor_registry` — overrides `Codrift.ConductorRegistry` (useful in tests)
  """
  def start_link(opts) do
    registry = Keyword.get(opts, :conductor_registry, Codrift.ConductorRegistry)
    id = Keyword.fetch!(opts, :initiative_id)

    name_opt =
      if registry && Process.whereis(registry),
        do: [name: {:via, Registry, {registry, id}}],
        else: []

    GenServer.start_link(__MODULE__, opts, name_opt)
  end

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

    state = %__MODULE__{
      initiative_id: initiative_id,
      adapter: adapter,
      context_dir: context_dir,
      agent_supervisor: agent_supervisor
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
    agents =
      start_agents_for_dirs(state.initiative_id, state.adapter, dirs, state.agent_supervisor)

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
        orchestration = read_orchestration(state.initiative_id, ctx_dir)
        prompt = orchestrator_prompt(state.initiative_id, dirs, task, adapter_name, orchestration)
        AgentProcess.send_input(pid, prompt)

        {:noreply, %{state | agents: agents, orchestrator_id: id}}

      {:error, reason} ->
        Logger.error(
          "[Conductor #{state.initiative_id}] failed to start orchestrator: #{inspect(reason)}"
        )

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
    out = Map.new(state.results, fn {id, {chunks, _count}} -> {id, Enum.reverse(chunks)} end)
    {:reply, out, state}
  end

  def handle_call(:agent_status, _from, state) do
    summary =
      Map.new(state.agents, fn {id, info} ->
        {id, %{dir: info.dir, status: info.status, role: info.role}}
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
      Map.update(state.results, id, {[data], 1}, fn {prev, n} ->
        if n >= @max_chunks,
          do: {[data | Enum.take(prev, @max_chunks - 1)], n},
          else: {[data | prev], n + 1}
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
    Enum.reduce(Enum.filter(dirs, &File.dir?/1), %{}, fn dir, acc ->
      case AgentSupervisor.start_agent(initiative_id, dir, adapter, server: agent_supervisor) do
        {:ok, pid} ->
          AgentProcess.subscribe(pid)
          %{id: id} = AgentProcess.status(pid)
          Map.put(acc, id, %{pid: pid, dir: dir, status: :starting, role: :worker})

        {:error, reason} ->
          Logger.error(
            "[Conductor #{initiative_id}] failed to start agent for #{dir}: #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  defp notify(%{subscribers: subs}, msg) do
    for {pid, _} <- subs, do: send(pid, msg)
  end

  defp read_orchestration(initiative_id, ctx_dir) do
    path = Path.join(ctx_dir, "orchestration.md")

    case File.read(path) do
      {:ok, content} ->
        content

      {:error, _} ->
        case Store.read_orchestration_md(initiative_id) do
          {:ok, content} -> content
          {:error, _} -> ""
        end
    end
  end

  defp orchestrator_prompt(initiative_id, dirs, task, adapter_name, orchestration) do
    dir_list = Enum.map_join(dirs, "\n", &"  - #{&1}")

    orchestration_section =
      if String.trim(orchestration) != "",
        do: "## Orchestration context\n\n#{String.trim(orchestration)}\n\n",
        else: ""

    """
    You are the orchestrator agent for initiative `#{initiative_id}`.

    #{orchestration_section}## Task
    #{task}

    ## Working directories
    #{dir_list}

    ## Instructions
    Use the Codrift MCP tools to coordinate this work across the directories above:

    1. **Plan** — read the orchestration context and task above, then decide what each directory's agent should do.
    2. **Start agents** — call `start_agent` for each directory with adapter `#{adapter_name}`.
    3. **Assign work** — call `send_to_agent` with a focused prompt per agent. Each agent only knows its own directory; be specific.
    4. **Monitor** — poll `get_agent_output` and `get_initiative_agents` to track progress.
    5. **Coordinate** — use `memory_search` before dispatching to avoid duplicating decisions. Use `memory_add` (type: decision) to record choices that affect multiple agents.
    6. **Synthesise** — once all agents are idle or stopped, reconcile their output and write a `summary` via `memory_add`.

    Call `broadcast_to_initiative` when all agents need the same message.

    Begin now.
    """
  end
end

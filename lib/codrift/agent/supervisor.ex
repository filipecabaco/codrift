defmodule Codrift.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor that manages running `AgentProcess` instances.

  Pass `name: nil` to start an unnamed instance for test isolation.
  All mutating functions accept an optional `server` argument (defaults to
  the globally registered `__MODULE__`) for the same reason.
  """

  use DynamicSupervisor

  alias Codrift.Web.EventRelay

  @doc "Starts the supervisor. Accepts `:name` opt (pass `nil` for unnamed)."
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> DynamicSupervisor.start_link(__MODULE__, [])
      name -> DynamicSupervisor.start_link(__MODULE__, [], name: name)
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Spawns a new agent for the given initiative directory and adapter module.

  Accepts keyword opts:
  - `:id` — reuse a specific agent ID (e.g. from `SessionStore` on restart); defaults to a new random ID
  - `:server` — supervisor to start the child under; defaults to `__MODULE__`
  - `:profile` — the launch profile name this agent runs under, or `nil`
  - `:profile_env` — `[{"KEY", "VALUE"}]` env overrides injected at spawn
  - `:command` — absolute executable to run instead of the adapter's own, or `nil`
  - `:extra_args` — arguments appended to the adapter's own at spawn
  """
  def start_agent(initiative_id, dir, adapter, opts \\ []) do
    id = Keyword.get(opts, :id, Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
    server = Keyword.get(opts, :server, __MODULE__)

    spec =
      {Codrift.AgentProcess,
       [
         id: id,
         initiative_id: initiative_id,
         dir: dir,
         adapter: adapter,
         profile: Keyword.get(opts, :profile),
         profile_env: Keyword.get(opts, :profile_env, []),
         command: Keyword.get(opts, :command),
         extra_args: Keyword.get(opts, :extra_args, [])
       ]}

    case DynamicSupervisor.start_child(server, spec) do
      {:ok, pid} = ok ->
        announce_to_watchers(pid)
        ok

      other ->
        other
    end
  end

  # Watchers subscribe to the agents present when they connect, so later agents
  # must be wired up and announced here — otherwise an agent spawned by an
  # orchestrator or the CLI never reaches an open window.
  defp announce_to_watchers(agent_pid) do
    Registry.dispatch(Codrift.AgentWatchers, :all, fn watchers ->
      Enum.each(watchers, fn {watcher, _} ->
        Codrift.AgentProcess.subscribe(agent_pid, watcher)
        send(watcher, {:agent_started, EventRelay.describe(agent_pid)})
      end)
    end)
  rescue
    ArgumentError -> :ok
  end

  @doc "Terminates a running agent by PID."
  def stop_agent(pid, server \\ __MODULE__) do
    DynamicSupervisor.terminate_child(server, pid)
  end

  @doc "Returns PIDs of all running agents under the given supervisor."
  def list_agents(server \\ __MODULE__) do
    server
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @doc """
  Looks up a running agent by its string ID via the Registry.

  Returns `{:ok, pid}` or `{:error, :not_found}`.
  """
  def find_agent(id, registry \\ Codrift.AgentRegistry) do
    case Registry.lookup(registry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns PIDs of all agents whose `initiative_id` matches.

  Uses the Registry (O(1) lookup) instead of calling `status/1` on every agent.
  The `initiative_id` is stored as Registry metadata when each agent registers itself.
  """
  def list_agents_for_initiative(initiative_id, registry \\ Codrift.AgentRegistry) do
    Registry.select(registry, [
      {{:_, :"$1", %{initiative_id: initiative_id}}, [], [:"$1"]}
    ])
  end
end

defmodule Codrift.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor that manages running `AgentProcess` instances.

  Pass `name: nil` to start an unnamed instance for test isolation.
  All mutating functions accept an optional `server` argument (defaults to
  the globally registered `__MODULE__`) for the same reason.
  """

  use DynamicSupervisor

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

  @doc "Spawns a new agent for the given initiative directory and adapter module."
  def start_agent(initiative_id, dir, adapter, server \\ __MODULE__) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    spec =
      {Codrift.AgentProcess, [id: id, initiative_id: initiative_id, dir: dir, adapter: adapter]}

    DynamicSupervisor.start_child(server, spec)
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

  @doc "Returns PIDs of all agents whose `initiative_id` matches."
  def list_agents_for_initiative(initiative_id, server \\ __MODULE__) do
    Enum.filter(list_agents(server), fn pid ->
      match?(%{initiative_id: ^initiative_id}, Codrift.AgentProcess.status(pid))
    end)
  end
end

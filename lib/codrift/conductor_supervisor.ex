defmodule Codrift.ConductorSupervisor do
  @moduledoc """
  DynamicSupervisor that manages running `Conductor` instances.

  One Conductor per initiative. Pass `name: nil` for test isolation.
  """

  use DynamicSupervisor

  alias Codrift.Initiative.DirEntry

  @doc "Starts the supervisor. Accepts `:name` opt (pass `nil` for unnamed)."
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> DynamicSupervisor.start_link(__MODULE__, [])
      name -> DynamicSupervisor.start_link(__MODULE__, [], name: name)
    end
  end

  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Starts a Conductor in fan-out mode: one agent per directory, all started
  immediately. Useful for broadcast-style work where every dir gets the same
  prompt.

  Accepts an optional `server:` keyword to target a specific supervisor
  instance (useful in tests).
  """
  def start_conductor(initiative, adapter, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    dirs = resolve_dirs(initiative)
    child_opts = [initiative_id: initiative.id, dirs: dirs, adapter: adapter] ++ passthrough(opts)
    DynamicSupervisor.start_child(server, {Codrift.Conductor, child_opts})
  end

  @doc """
  Starts a Conductor in orchestrator mode: launches one Claude agent in the
  initiative's context directory and gives it `task` as a planning prompt.
  That agent uses the Codrift MCP tools to start and direct sub-agents itself.

  Accepts an optional `server:` keyword to target a specific supervisor
  instance (useful in tests).
  """
  def start_orchestration(initiative, adapter, task, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    dirs = resolve_dirs(initiative)
    child_opts = [initiative_id: initiative.id, dirs: dirs, adapter: adapter, task: task] ++ passthrough(opts)
    DynamicSupervisor.start_child(server, {Codrift.Conductor, child_opts})
  end

  @doc """
  Looks up the running Conductor for `initiative_id`.

  Returns `{:ok, pid}` or `{:error, :not_found}`.
  """
  def find_conductor(initiative_id, registry \\ Codrift.ConductorRegistry) do
    case Registry.lookup(registry, initiative_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc "Terminates the Conductor for `initiative_id`, if one is running."
  def stop_conductor(initiative_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    registry = Keyword.get(opts, :registry, Codrift.ConductorRegistry)

    case find_conductor(initiative_id, registry) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(server, pid)
      {:error, :not_found} -> :ok
    end
  end

  @doc "Returns PIDs of all running conductors."
  def list_conductors(server \\ __MODULE__) do
    server
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  defp resolve_dirs(initiative) do
    initiative.dirs
    |> Enum.map(&DirEntry.effective_path/1)
    |> Enum.filter(&File.dir?/1)
  end

  # Keys forwarded from opts to Conductor child opts.
  @passthrough_keys [:agent_supervisor, :conductor_registry, :context_dir]

  defp passthrough(opts) do
    Enum.flat_map(@passthrough_keys, fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, val} -> [{key, val}]
        :error -> []
      end
    end)
  end
end

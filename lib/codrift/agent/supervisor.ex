defmodule Codrift.AgentSupervisor do
  use DynamicSupervisor

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

  def start_agent(initiative_id, dir, adapter, server \\ __MODULE__) do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    spec =
      {Codrift.AgentProcess, [id: id, initiative_id: initiative_id, dir: dir, adapter: adapter]}

    DynamicSupervisor.start_child(server, spec)
  end

  def stop_agent(pid, server \\ __MODULE__) do
    DynamicSupervisor.terminate_child(server, pid)
  end

  def list_agents(server \\ __MODULE__) do
    DynamicSupervisor.which_children(server)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end
end

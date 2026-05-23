defmodule Codrift do
  use Francis

  @impl true
  def start(_type, _args) do
    children = [
      Codrift.Initiative.Store,
      Codrift.AgentSupervisor,
      {Bandit, [plug: __MODULE__] ++ Application.get_env(:codrift, :bandit_opts, [])}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Codrift.Supervisor)
  end

  get("/", fn _ -> "ok" end)
  unmatched(fn _ -> "not found" end)
end

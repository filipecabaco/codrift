defmodule Codrift.AgentProcess do
  @moduledoc """
  GenServer that owns an OS Port to an external AI coding CLI process.

  Each instance is started under `AgentSupervisor` with `:temporary` restart
  policy — crashed agents are not automatically restarted.

  ## Output buffering

  Raw stdout chunks are stored in a ring buffer (capped at 1 000 entries,
  newest-first). Retrieve them with `recent_output/2`, which reverses the
  buffer before returning so callers receive chronological order.

  ## Subscriptions

  Any process can call `subscribe/2` to receive `{:agent_output, id, data}`
  and `{:agent_stopped, id, exit_code}` messages. The subscriber is monitored;
  if it exits the subscription is cleaned up automatically.
  """

  use GenServer

  defstruct [:id, :initiative_id, :dir, :adapter, :port, :status, :buffer, :subscribers]

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc "Starts an agent process. Required opts: `:id`, `:initiative_id`, `:dir`, `:adapter`."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Sends `text` to the agent's stdin followed by a newline."
  def send_input(pid, text), do: GenServer.cast(pid, {:input, text})

  @doc "Returns a status map: `%{id, initiative_id, dir, adapter, status}`."
  def status(pid), do: GenServer.call(pid, :status)

  @doc "Returns the `n` most recent output lines in chronological order."
  def recent_output(pid, n \\ 50), do: GenServer.call(pid, {:recent_output, n})

  @doc """
  Subscribes `subscriber` (defaults to `self()`) to output notifications.

  The subscriber will receive:
    - `{:agent_output, id, data}` for each stdout chunk
    - `{:agent_stopped, id, exit_code}` when the OS process exits
  """
  def subscribe(pid, subscriber \\ self()), do: GenServer.call(pid, {:subscribe, subscriber})

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    initiative_id = Keyword.fetch!(opts, :initiative_id)
    dir = Keyword.fetch!(opts, :dir)
    adapter = Keyword.fetch!(opts, :adapter)

    env =
      Enum.map(adapter.env(dir), fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    port_opts = [
      :use_stdio,
      :exit_status,
      :binary,
      {:cd, dir},
      {:env, env},
      {:args, adapter.args(dir)}
    ]

    port = Port.open({:spawn_executable, adapter.cmd()}, port_opts)

    if Process.whereis(Codrift.AgentRegistry) do
      Registry.register(Codrift.AgentRegistry, id, nil)
    end

    {:ok,
     %__MODULE__{
       id: id,
       initiative_id: initiative_id,
       dir: dir,
       adapter: adapter,
       port: port,
       status: :starting,
       buffer: [],
       subscribers: []
     }}
  end

  @impl true
  def handle_cast({:input, _text}, %{status: :stopped} = state), do: {:noreply, state}

  def handle_cast({:input, text}, state) do
    Port.command(state.port, text <> "\n")
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    info = %{
      id: state.id,
      initiative_id: state.initiative_id,
      dir: state.dir,
      adapter: state.adapter,
      status: state.status
    }

    {:reply, info, state}
  end

  def handle_call({:recent_output, n}, _from, state) do
    output = state.buffer |> Enum.take(n) |> Enum.reverse()
    {:reply, output, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_status = state.adapter.parse_status(data) || state.status
    new_buffer = Enum.take([data | state.buffer], 1_000)

    for subscriber <- state.subscribers do
      send(subscriber, {:agent_output, state.id, data})
    end

    {:noreply, %{state | buffer: new_buffer, status: new_status}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    for subscriber <- state.subscribers do
      send(subscriber, {:agent_stopped, state.id, code})
    end

    {:noreply, %{state | status: :stopped, port: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end

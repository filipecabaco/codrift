defmodule Codrift.AgentProcess do
  use GenServer

  defstruct [:id, :initiative_id, :dir, :adapter, :port, :status, :buffer, :subscribers]

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def send_input(pid, text), do: GenServer.cast(pid, {:input, text})
  def status(pid), do: GenServer.call(pid, :status)
  def recent_output(pid, n \\ 50), do: GenServer.call(pid, {:recent_output, n})
  def subscribe(pid, subscriber \\ self()), do: GenServer.call(pid, {:subscribe, subscriber})

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    initiative_id = Keyword.fetch!(opts, :initiative_id)
    dir = Keyword.fetch!(opts, :dir)
    adapter = Keyword.fetch!(opts, :adapter)

    cmd = adapter.cmd()
    args = adapter.args(dir)

    env =
      adapter.env(dir)
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port_opts = [:use_stdio, :exit_status, :binary, {:cd, dir}, {:env, env}, {:args, args}]

    port = Port.open({:spawn_executable, cmd}, port_opts)

    state = %__MODULE__{
      id: id,
      initiative_id: initiative_id,
      dir: dir,
      adapter: adapter,
      port: port,
      status: :starting,
      buffer: [],
      subscribers: []
    }

    {:ok, state}
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
    new_buffer = [data | state.buffer] |> Enum.take(1_000)

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

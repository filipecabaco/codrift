defmodule Codrift.AgentProcess do
  @moduledoc """
  GenServer that manages an AI coding CLI agent.

  Supports two invocation modes determined by the adapter's `mode/0` callback:

  - `:interactive` — opens one long-running Port on startup; text is sent
    to its stdin. Suitable for CLIs like Aider.

  - `:once` — starts with no Port; each call to `send_input/2` spawns a
    fresh process with the text as a trailing CLI argument. The adapter's
    `args/1` is used for the first message and `args_continue/1` for
    subsequent ones. Suitable for `claude --print --continue`.

  ## Output buffering

  Chunks are stored newest-first in a ring buffer (cap: 1 000 entries).
  `recent_output/2` reverses the buffer before returning.

  ## Subscriptions

  Subscribers receive:
  - `{:agent_output, id, data}` — each stdout/stderr chunk
  - `{:agent_ready, id}` — `:once` mode: a turn completed successfully
  - `{:agent_stopped, id, exit_code}` — process exited (error in `:once`,
    any exit in `:interactive`)

  Subscribers are monitored; stale entries are cleaned up automatically.
  """

  use GenServer

  defstruct [
    :id,
    :initiative_id,
    :dir,
    :adapter,
    :mode,
    :port,
    :status,
    :buffer,
    :subscribers,
    :conversation_started
  ]

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc "Starts an agent process. Required opts: `:id`, `:initiative_id`, `:dir`, `:adapter`."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Sends `text` to the agent.

  `:interactive` — writes to stdin. `:once` — spawns a new process with
  the text as the final CLI argument.
  """
  def send_input(pid, text), do: GenServer.cast(pid, {:input, text})

  @doc "Returns `%{id, initiative_id, dir, adapter, status, mode}`."
  def status(pid), do: GenServer.call(pid, :status)

  @doc "Returns the `n` most recent output lines in chronological order."
  def recent_output(pid, n \\ 50), do: GenServer.call(pid, {:recent_output, n})

  @doc """
  Subscribes `subscriber` (defaults to `self()`) to output notifications.
  """
  def subscribe(pid, subscriber \\ self()), do: GenServer.call(pid, {:subscribe, subscriber})

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    initiative_id = Keyword.fetch!(opts, :initiative_id)
    dir = Keyword.fetch!(opts, :dir)
    adapter = Keyword.fetch!(opts, :adapter)
    mode = adapter_mode(adapter)

    if Process.whereis(Codrift.AgentRegistry) do
      Registry.register(Codrift.AgentRegistry, id, nil)
    end

    base = %__MODULE__{
      id: id,
      initiative_id: initiative_id,
      dir: dir,
      adapter: adapter,
      mode: mode,
      port: nil,
      buffer: [],
      subscribers: [],
      conversation_started: false
    }

    case mode do
      :interactive ->
        port = open_port(adapter, dir, adapter.args(dir))
        {:ok, %{base | port: port, status: :starting}}

      :once ->
        {:ok, %{base | status: :idle}}
    end
  end

  @impl true
  def handle_cast({:input, _text}, %{mode: :interactive, status: :stopped} = state),
    do: {:noreply, state}

  def handle_cast({:input, text}, %{mode: :interactive} = state) do
    Port.command(state.port, text <> "\n")
    {:noreply, %{state | status: :running}}
  end

  def handle_cast({:input, _text}, %{mode: :once, port: port} = state) when not is_nil(port) do
    {:noreply, %{state | status: "busy — previous message still running"}}
  end

  def handle_cast({:input, text}, %{mode: :once} = state) do
    args = once_args(state.adapter, state.dir, state.conversation_started) ++ [text]
    port = open_port(state.adapter, state.dir, args)
    {:noreply, %{state | port: port, status: :running}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       id: state.id,
       initiative_id: state.initiative_id,
       dir: state.dir,
       adapter: state.adapter,
       status: state.status,
       mode: state.mode
     }, state}
  end

  def handle_call({:recent_output, n}, _from, state) do
    {:reply, state.buffer |> Enum.take(n) |> Enum.reverse(), state}
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

  def handle_info({port, {:exit_status, 0}}, %{port: port, mode: :once} = state) do
    for subscriber <- state.subscribers do
      send(subscriber, {:agent_ready, state.id})
    end

    {:noreply, %{state | port: nil, status: :idle, conversation_started: true}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port, mode: :once} = state) do
    error_line = "\n[agent exited with code #{code}]\n"
    new_buffer = Enum.take([error_line | state.buffer], 1_000)

    for subscriber <- state.subscribers do
      send(subscriber, {:agent_stopped, state.id, code})
    end

    {:noreply,
     %{state | port: nil, status: :idle, buffer: new_buffer, conversation_started: true}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port, mode: :interactive} = state) do
    new_buffer =
      if code != 0 do
        Enum.take(["\n[agent exited with code #{code}]\n" | state.buffer], 1_000)
      else
        state.buffer
      end

    for subscriber <- state.subscribers do
      send(subscriber, {:agent_stopped, state.id, code})
    end

    {:noreply, %{state | status: :stopped, port: nil, buffer: new_buffer}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp adapter_mode(adapter), do: adapter.mode()

  defp once_args(adapter, dir, false), do: adapter.args(dir)
  defp once_args(adapter, dir, true), do: adapter.args_continue(dir)

  defp open_port(adapter, dir, args) do
    env =
      Enum.map(adapter.env(dir), fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    port_opts = [
      :use_stdio,
      :exit_status,
      :binary,
      :stderr_to_stdout,
      {:cd, dir},
      {:env, env},
      {:args, args}
    ]

    Port.open({:spawn_executable, adapter.cmd()}, port_opts)
  end
end

defmodule Codrift.AgentProcess do
  @moduledoc """
  GenServer that manages an AI coding CLI agent.

  Supports three invocation modes determined by the adapter's `mode/0`:

  - `:pty` — allocates a pseudo-terminal via `erlexec` so the CLI gets
    a real terminal. ANSI colors and interactive features work. Claude
    Code requires this to avoid switching to `--print` mode.

  - `:interactive` — long-running Port with plain pipes (no PTY). Suitable
    for CLIs that work without a TTY.

  - `:once` — spawns a fresh Port per message with the text as a trailing
    CLI argument. Uses `args_continue/1` for subsequent turns.

  ## Output buffering

  Chunks are held oldest-first in a bounded `:queue` (cap: 1 000 entries), and
  every chunk is also appended to a durable transcript log at
  `<context>/.agent-logs/<agent_id>.log` (see `Codrift.AgentLogs`), so output
  survives agent and Codrift restarts.

  The queue is not an ornament. This is the hottest path in Codrift — a
  full-screen TUI agent emits a chunk per repaint, and each one lands here — so
  it has to be O(1). The previous list did `[data | Enum.take(buffer, 999)]`
  once the cap was reached, rebuilding a 999-cons list *per chunk*: measured at
  118 ms per 20 000 chunks against 0.5 ms for the queue, and all of that
  difference is garbage the agent's process then has to collect.

  ## Exit status

  When the underlying CLI exits, the GenServer stays alive so the transcript
  remains queryable: status becomes `:stopped` on a clean exit (code 0) and
  `:crashed` on a non-zero exit, so supervisors can tell a finished agent
  from a dead one.

  ## Subscriptions

  Subscribers receive:
  - `{:agent_output, id, data}` — each stdout/stderr chunk
  - `{:agent_ready, id}` — `:once` turn completed successfully
  - `{:agent_stopped, id, exit_code}` — process exited
  """

  use GenServer
  require Logger

  alias Codrift.Initiative.Store

  defstruct [
    :id,
    :initiative_id,
    :dir,
    :adapter,
    :mode,
    :exec_pid,
    :exec_ospid,
    :port,
    :status,
    :buffer,
    :buffer_size,
    :buffer_bytes,
    :subscribers,
    :conversation_started,
    :raw_line_buf,
    :session_uuid,
    :profile,
    :command,
    :log_fd,
    profile_env: [],
    extra_args: [],
    last_size: nil
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

  @doc "Sends `text` followed by a newline. For `:pty` mode, use `send_raw/2` to forward individual keypresses."
  def send_input(pid, text), do: GenServer.cast(pid, {:input, text})

  @doc "Sends raw bytes directly to the process stdin — use for `:pty` keypress forwarding."
  def send_raw(pid, data), do: GenServer.cast(pid, {:raw, data})

  @doc "Notifies the PTY of a terminal resize (`:pty` mode only)."
  def resize(pid, cols, rows), do: GenServer.cast(pid, {:resize, cols, rows})

  @doc "Returns `%{id, initiative_id, dir, adapter, status, mode}`."
  def status(pid), do: GenServer.call(pid, :status)

  # Two caps, because one of them alone is a lie about memory. A thousand chunks
  # is enough to repaint any terminal, but "a chunk" is whatever the PTY handed
  # us — a few bytes of echo, or a full-screen redraw — so a count alone leaves
  # the real ceiling up to how the agent happens to flush. The byte cap makes it
  # a number: an agent holds at most a megabyte of scrollback, which is twenty
  # times a full 200x50 screen of dense ANSI. Older bytes are not lost, they are
  # in the transcript log.
  @buffer_limit 1_000
  @buffer_bytes_limit 1_048_576

  @doc "Returns the `n` most recent output lines in chronological order."
  def recent_output(pid, n \\ 50), do: GenServer.call(pid, {:recent_output, n})

  @doc "Returns the Claude Code session UUID detected from disk after startup, or nil."
  def session_uuid(pid), do: GenServer.call(pid, :session_uuid)

  @doc "Subscribes `subscriber` (defaults to `self()`) to output notifications."
  def subscribe(pid, subscriber \\ self()), do: GenServer.call(pid, {:subscribe, subscriber})

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    initiative_id = Keyword.fetch!(opts, :initiative_id)
    dir = Keyword.fetch!(opts, :dir)
    adapter = Keyword.fetch!(opts, :adapter)
    profile = Keyword.get(opts, :profile)
    profile_env = Keyword.get(opts, :profile_env, [])
    command = Keyword.get(opts, :command)
    extra_args = Keyword.get(opts, :extra_args, [])
    mode = adapter.mode()

    if Process.whereis(Codrift.AgentRegistry) do
      Registry.register(Codrift.AgentRegistry, id, %{initiative_id: initiative_id})
    end

    base = %__MODULE__{
      id: id,
      initiative_id: initiative_id,
      dir: dir,
      adapter: adapter,
      mode: mode,
      exec_pid: nil,
      exec_ospid: nil,
      port: nil,
      buffer: :queue.new(),
      buffer_size: 0,
      buffer_bytes: 0,
      subscribers: %{},
      conversation_started: false,
      raw_line_buf: "",
      profile: profile,
      profile_env: profile_env,
      command: command,
      extra_args: extra_args,
      log_fd: open_log(initiative_id, id)
    }

    # Generate or retrieve a stable session UUID before launching the process.
    # Passed as --session-id (first run) or --resume (subsequent runs) for
    # adapters that support session persistence. Storing it upfront means we
    # never need to scan the filesystem after startup to discover which UUID
    # was created.
    session_id =
      if adapter.session_persistable?(),
        do: ensure_session_id(id, initiative_id, dir, adapter)

    context_opts =
      [session_id: session_id, config_dir: profile_config_dir(profile_env)] ++
        initiative_context_opts(initiative_id)

    case mode do
      :pty ->
        # Profile env comes last so it overrides adapter defaults (dedup keeps
        # the last occurrence per key). The unsets come first so a profile that
        # deliberately sets one of those names still wins.
        env =
          dedup_env(
            clear_release_env() ++
              [{"TERM", "xterm-256color"} | adapter.env(dir)] ++ profile_env
          )

        args = adapter.args(dir, context_opts) ++ extra_args

        # erlexec requires args to be passed as [executable | args] list rather
        # than the {:args, [...]} option (which is invalid in PTY mode).
        executable = command || adapter.cmd()
        cmd = if args == [], do: executable, else: [executable | args]

        # stderr must be captured as well as stdout. On Linux an interactive
        # shell writes its prompt — and every "command not found" — to stderr,
        # so a stdout-only PTY yields a terminal that displays absolutely
        # nothing. (macOS happens to surface the prompt on stdout, which is why
        # this only ever showed up on Linux.)
        pty_opts = [
          :pty,
          :stdin,
          {:stdout, self()},
          {:stderr, self()},
          :monitor,
          {:cd, dir},
          {:env, env}
        ]

        {:ok, exec_pid, ospid} = :exec.run(cmd, pty_opts)

        {:ok,
         %{
           base
           | exec_pid: exec_pid,
             exec_ospid: ospid,
             status: :starting,
             session_uuid: session_id
         }}

      :interactive ->
        args = adapter.args(dir, context_opts) ++ extra_args
        port = open_port(adapter, dir, args, profile_env, command)
        {:ok, %{base | port: port, status: :starting}}

      :once ->
        {:ok, %{base | status: :idle}}
    end
  end

  @impl true
  def handle_cast({:input, _text}, %{mode: :interactive, status: :stopped} = state),
    do: {:noreply, state}

  def handle_cast({:raw, data}, %{mode: :pty, exec_pid: pid} = state) when not is_nil(pid) do
    :exec.send(pid, data)
    {:noreply, state}
  end

  def handle_cast({:raw, _data}, %{mode: :pty} = state), do: {:noreply, state}

  def handle_cast({:raw, data}, %{mode: :interactive} = state) do
    Port.command(state.port, data)
    {:noreply, state}
  end

  def handle_cast({:raw, _data}, state), do: {:noreply, state}

  def handle_cast({:resize, cols, rows}, %{mode: :pty, exec_ospid: ospid} = state)
      when not is_nil(ospid) and {cols, rows} != state.last_size do
    :exec.winsz(ospid, rows, cols)
    {:noreply, %{state | last_size: {cols, rows}}}
  rescue
    _ -> {:noreply, state}
  end

  def handle_cast({:resize, _cols, _rows}, state), do: {:noreply, state}

  def handle_cast({:input, text}, %{mode: :pty} = state) do
    :exec.send(state.exec_pid, text <> "\r\n")
    {:noreply, %{state | status: :running}}
  end

  def handle_cast({:input, text}, %{mode: :interactive} = state) do
    Port.command(state.port, text <> "\n")
    {:noreply, %{state | status: :running}}
  end

  def handle_cast({:input, _text}, %{mode: :once, port: port} = state) when not is_nil(port) do
    {:noreply, state}
  end

  def handle_cast({:input, text}, %{mode: :once} = state) do
    args =
      once_args(state.adapter, state.dir, state.conversation_started) ++
        state.extra_args ++ [text]

    port = open_port(state.adapter, state.dir, args, state.profile_env, state.command)
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
       mode: state.mode,
       profile: state.profile
     }, state}
  end

  def handle_call(:session_uuid, _from, state) do
    {:reply, state.session_uuid, state}
  end

  def handle_call({:recent_output, n}, _from, state) do
    # O(size), but only on an explicit replay — never per chunk, which is the
    # whole point of the queue.
    {:reply, state.buffer |> :queue.to_list() |> Enum.take(-n), state}
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
  # PTY output from erlexec. A terminal interleaves both streams on the same
  # screen, so both are fed through the same path.
  def handle_info({stream, ospid, data}, %{exec_ospid: ospid} = state)
      when stream in [:stdout, :stderr] do
    {:noreply, process_output(state, data)}
  end

  # PTY process exited (erlexec monitor message)
  def handle_info({:DOWN, ospid, :process, _pid, reason}, %{exec_ospid: ospid} = state) do
    exit_code =
      case reason do
        {:exit_status, code} when is_integer(code) -> code
        {_status, code} when is_integer(code) -> code
        _ -> 0
      end

    Logger.info(
      "Agent #{state.id} (#{state.adapter}) PTY process #{ospid} exited: #{inspect(reason)}, code=#{exit_code}"
    )

    handle_exit(state, exit_code)
  end

  # Port output (interactive / once modes)
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, process_output(state, data)}
  end

  # Port exit in :once mode — go back to :idle
  def handle_info({port, {:exit_status, 0}}, %{port: port, mode: :once} = state) do
    for {sub, _} <- state.subscribers, do: send(sub, {:agent_ready, state.id})
    {:noreply, %{state | port: nil, status: :idle, conversation_started: true}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port, mode: :once} = state) do
    error = "\n[agent exited with code #{code}]\n"
    state = push_buffer(state, error)
    for {sub, _} <- state.subscribers, do: send(sub, {:agent_stopped, state.id, code})
    {:noreply, %{state | port: nil, status: :idle, conversation_started: true}}
  end

  # Port exit in :interactive mode
  def handle_info({port, {:exit_status, code}}, %{port: port, mode: :interactive} = state) do
    handle_exit(state, code)
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.log_fd, do: :file.close(state.log_fd)

    cond do
      state.exec_pid -> :exec.stop(state.exec_pid)
      state.port -> Port.close(state.port)
      true -> :ok
    end
  rescue
    _ -> :ok
  end

  defp process_output(%{mode: :once} = state, data) do
    # Claude stream-json: accumulate incomplete lines, extract text deltas
    combined = state.raw_line_buf <> data
    lines = String.split(combined, "\n")
    {complete, [leftover]} = Enum.split(lines, -1)

    text = Enum.map_join(complete, &extract_text_delta/1)

    if text == "" do
      %{state | raw_line_buf: leftover}
    else
      state = push_buffer(state, text)
      for {sub, _} <- state.subscribers, do: send(sub, {:agent_output, state.id, text})
      %{state | status: :running, raw_line_buf: leftover}
    end
  end

  defp process_output(state, data) do
    new_status = state.adapter.parse_status(data) || state.status
    state = push_buffer(state, data)
    for {sub, _} <- state.subscribers, do: send(sub, {:agent_output, state.id, data})

    if new_status != state.status, do: broadcast_status(state, new_status)

    %{state | status: new_status}
  end

  # Fans a status transition out to subscribers. `:awaiting_input` additionally
  # emits `:agent_ready`, which orchestrators treat as "safe to send input now".
  # Kept as two passes so every subscriber sees the status before any sees ready.
  defp broadcast_status(state, status) do
    for {sub, _} <- state.subscribers, do: send(sub, {:agent_status, state.id, status})

    if status == :awaiting_input do
      for {sub, _} <- state.subscribers, do: send(sub, {:agent_ready, state.id})
    end
  end

  defp extract_text_delta(line) do
    case JSON.decode(line) do
      {:ok,
       %{
         "type" => "content_block_delta",
         "delta" => %{"type" => "text_delta", "text" => text}
       }} ->
        text

      _ ->
        ""
    end
  end

  # Keeps the GenServer alive after the CLI exits so the buffer and status
  # stay queryable. A non-zero exit is surfaced as :crashed (distinct from a
  # clean :stopped) so orchestrators and the UI can tell them apart.
  defp handle_exit(state, code) do
    state =
      if code != 0,
        do: push_buffer(state, "\n[agent exited with code #{code}]\n"),
        else: state

    for {sub, _} <- state.subscribers, do: send(sub, {:agent_stopped, state.id, code})

    final_status = if code == 0, do: :stopped, else: :crashed
    {:noreply, %{state | exec_pid: nil, exec_ospid: nil, port: nil, status: final_status}}
  end

  # Bounded ring: push to the rear, evict from the front until both caps hold.
  # Every operation is O(1) at each end, so a chatty agent costs the same on its
  # millionth chunk as on its first.
  defp push_buffer(state, data) do
    log_write(state.log_fd, data)

    evict(%{
      state
      | buffer: :queue.in(data, state.buffer),
        buffer_size: state.buffer_size + 1,
        buffer_bytes: state.buffer_bytes + byte_size(data)
    })
  end

  # A single chunk larger than the byte cap would otherwise empty the queue and
  # then evict itself, so the last entry is always kept: a buffer holding one
  # oversized repaint is still worth more than an empty one.
  defp evict(%{buffer_size: size, buffer_bytes: bytes} = state)
       when size > @buffer_limit or bytes > @buffer_bytes_limit do
    case :queue.out(state.buffer) do
      {{:value, oldest}, rest} when size > 1 ->
        evict(%{
          state
          | buffer: rest,
            buffer_size: size - 1,
            buffer_bytes: bytes - byte_size(oldest)
        })

      _ ->
        state
    end
  end

  defp evict(state), do: state

  # Opens the durable transcript log (see Codrift.AgentLogs). Best-effort: a
  # failure to open degrades to in-memory-only buffering, never a dead agent.
  defp open_log(initiative_id, agent_id) do
    path = Codrift.Paths.agent_log(initiative_id, agent_id)
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:append, :raw, :binary]) do
      {:ok, fd} ->
        fd

      {:error, reason} ->
        Logger.warning(
          "Agent #{agent_id}: cannot open transcript log #{path}: #{inspect(reason)}"
        )

        nil
    end
  rescue
    e ->
      Logger.warning("Agent #{agent_id}: cannot create transcript log dir: #{inspect(e)}")
      nil
  end

  defp log_write(nil, _data), do: :ok

  defp log_write(fd, data) do
    :file.write(fd, data)
    :ok
  end

  defp dedup_env(env) do
    env
    |> Enum.reverse()
    |> Enum.uniq_by(fn {k, _v} -> k end)
    |> Enum.reverse()
  end

  # Variables that identify *this* BEAM's release and ERTS. Both spawners
  # inherit the sidecar's environment, so without clearing these an agent — and
  # everything it runs — is handed the desktop app's release identity.
  #
  # The one that bites is RELEASE_SYS_CONFIG: a release boot script only
  # defaults it, so an inherited value wins, and the sys.config it names pins
  # the config provider to the *app's* version. An agent running `codrift memory
  # add` against a CLI of a different version then dies at boot with
  # "could not read .../releases/<app version>/runtime.exs" — which is every
  # user mid-upgrade, since the cask and the codrift-cli formula move
  # separately. __BURRITO is the other: `Codrift.desktop_sidecar?/0` reads it,
  # so a leaked copy makes a child believe it is the desktop sidecar.
  #
  # `{name, false}` is "unset" to both erlexec and Erlang ports.
  @inherited_release_vars ~w(
    RELEASE_ROOT RELEASE_SYS_CONFIG RELEASE_NAME RELEASE_VSN RELEASE_COOKIE
    RELEASE_NODE RELEASE_TMP RELEASE_MODE RELEASE_DISTRIBUTION RELEASE_BOOT_SCRIPT
    RELEASE_BOOT_SCRIPT_CLEAN RELEASE_PROG RELEASE_COMMAND
    __BURRITO __BURRITO_BIN_PATH BINDIR ROOTDIR EMU PROGNAME
  )

  defp clear_release_env, do: Enum.map(@inherited_release_vars, &{&1, false})

  defp once_args(adapter, dir, false), do: adapter.args(dir, [])
  defp once_args(adapter, dir, true), do: adapter.args_continue(dir)

  # Returns the stored session UUID for this agent, or generates and stores a
  # new one. Called before the process launches so the UUID is always known
  # upfront and can be passed directly as --session-id or --resume.
  defp ensure_session_id(agent_id, initiative_id, dir, adapter) do
    case Codrift.SessionStore.get_by_agent(agent_id) do
      {:ok, uuid} ->
        uuid

      {:error, :not_found} ->
        uuid = generate_uuid()

        Codrift.SessionStore.save(
          agent_id,
          initiative_id,
          dir,
          uuid,
          Codrift.Agent.adapter_name(adapter)
        )

        uuid
    end
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c4 = :erlang.bor(:erlang.band(c, 0x0FFF), 0x4000)
    d8 = :erlang.bor(:erlang.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c4, d8, e])
    |> IO.chardata_to_string()
  end

  # Collects all non-hidden files in the initiative's context folder (excluding
  # CLAUDE.md, which is a symlink handled via --add-dir) and returns context
  # opts for adapters:
  #
  #   context_dir:   the context folder path (for --add-dir in Claude adapter)
  #   context_files: list of absolute file paths passed to adapters that support them
  defp initiative_context_opts(initiative_id) do
    ctx_dir = Store.context_path(initiative_id)

    base = if File.dir?(ctx_dir), do: [context_dir: ctx_dir], else: []

    files =
      case File.ls(ctx_dir) do
        {:ok, names} ->
          names
          |> Enum.reject(&(String.starts_with?(&1, ".") or &1 == "CLAUDE.md"))
          |> Enum.sort()
          |> Enum.map(&Path.join(ctx_dir, &1))
          |> Enum.filter(&File.regular?/1)

        {:error, _} ->
          []
      end

    base ++ if(files == [], do: [], else: [context_files: files])
  end

  defp profile_config_dir(profile_env) do
    case List.keyfind(profile_env, "CLAUDE_CONFIG_DIR", 0) do
      {_, dir} -> dir
      nil -> nil
    end
  end

  defp open_port(adapter, dir, args, extra_env, command) do
    env =
      (clear_release_env() ++ adapter.env(dir) ++ extra_env)
      |> dedup_env()
      |> Enum.map(fn
        {k, false} -> {String.to_charlist(k), false}
        {k, v} -> {String.to_charlist(k), String.to_charlist(v)}
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

    Port.open({:spawn_executable, command || adapter.cmd()}, port_opts)
  end
end

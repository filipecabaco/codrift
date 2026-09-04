defmodule Codrift.ShutdownManager do
  @moduledoc """
  Heartbeat-based shutdown for the Tauri desktop sidecar.

  The Rust shell connects to a Unix domain socket and writes a byte every 100ms.
  Two things end this backend:

    * the connection closing and nothing reconnecting — the kernel closes a dead
      process's sockets, so this is the unambiguous "window gone" signal, and the
      one a crash or force-quit actually trips;
    * bytes stopping for `timeout` while the connection stays open — the backstop
      for a shell that is alive but wedged.

  Drop-in replacement for `ExTauri.ShutdownManager` with three correctness fixes.

  **The timeout is only enforced after the first heartbeat is received.** The
  upstream version arms the 1500ms timeout at `init`, so a slow boot — the chain
  of this process starting, Bandit binding `:43117`, the Rust shell polling and
  detecting the port, connecting the socket, then sending the first byte — that
  exceeds the timeout makes the backend `System.stop/0` itself mid-startup,
  leaving the window pointed at a dead server (`ERR_CONNECTION_REFUSED`). Normal
  exits are already handled by the Rust shell (SIGTERM on window close /
  ExitRequested), so a state where no heartbeat has *ever* arrived must never
  trigger shutdown.

  **A check that runs late rebaselines instead of shutting down.** When the
  machine sleeps both sides freeze, they do not resume together, and the
  monotonic clock keeps running across the sleep — so the first check after a
  wake measures a gap that says nothing about whether the window is alive. That
  is how an ordinary lid-close killed the backend: `heartbeat lost (1610ms) —
  window gone` moments after the wake, with the shell still on screen. A check
  more than `@stall_grace` later than it was scheduled proves *this* process was
  not running either, which makes every elapsed measurement across it
  meaningless, so the baseline is reset and the window given another interval.

  **The timeout is no longer 1.5s.** With the closed connection doing the real
  work, a gap in the bytes only has to catch a wedged shell, and 1.5s is well
  inside what a busy machine costs a 100ms writer thread — the wake that stalls
  this process stalls that one too.
  """

  use GenServer
  require Logger

  @default_heartbeat_interval 500
  @default_heartbeat_timeout 30_000
  # A check running this much later than scheduled means the VM was frozen
  # (system sleep, SIGSTOP), not that the shell stopped writing.
  @default_stall_grace 1_000
  # How long the socket may stay closed before the window counts as gone. The
  # Rust shell retries every 100ms, so this only has to outlast a reconnect.
  @default_reconnect_grace 3_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    interval = setting(opts, :interval, :heartbeat_interval, @default_heartbeat_interval)
    timeout = setting(opts, :timeout, :heartbeat_timeout, @default_heartbeat_timeout)
    stall_grace = Keyword.get(opts, :stall_grace, @default_stall_grace)
    reconnect_grace = Keyword.get(opts, :reconnect_grace, @default_reconnect_grace)
    on_stop = Keyword.get(opts, :on_stop, fn -> System.stop(0) end)

    # Socket name mirrors what the Rust shell connects to: ExTauri's installer
    # sanitises the app name into main.rs (here "Codrift" -> "codrift"). Inlined
    # rather than calling ExTauri.Paths so this carries no runtime dep on ex_tauri.
    app_name = setting(opts, :app_name, :app_name, "Codrift")

    socket_path =
      Path.join(System.tmp_dir!(), "tauri_heartbeat_#{sanitize_name(app_name)}.sock")

    remove_stale_socket(socket_path)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, socket_path}},
        {:active, false},
        {:reuseaddr, true}
      ])

    File.chmod(socket_path, 0o600)
    manager = self()

    Task.Supervisor.start_child(Codrift.TaskSupervisor, fn ->
      accept_loop(listen_socket, manager)
    end)

    Logger.info("[Codrift.ShutdownManager] heartbeat monitoring on #{socket_path}")

    {:ok,
     %{
       listen_socket: listen_socket,
       socket_path: socket_path,
       last_heartbeat: System.monotonic_time(:millisecond),
       next_check: schedule_check(interval),
       # Stays false until the Rust shell has connected at least once. While
       # false, a timeout is the still-booting case, not a lost window.
       connected: false,
       # When the shell's connection dropped, if it is currently down.
       disconnected_at: nil,
       shutdown_initiated: false,
       interval: interval,
       timeout: timeout,
       stall_grace: stall_grace,
       reconnect_grace: reconnect_grace,
       on_stop: on_stop
     }}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    {:noreply,
     %{
       state
       | last_heartbeat: System.monotonic_time(:millisecond),
         connected: true,
         disconnected_at: nil
     }}
  end

  # The shell's connection ended. Before the first heartbeat this says nothing —
  # anything can open the socket — so it only counts once the shell has spoken.
  def handle_cast(:client_gone, %{connected: true, disconnected_at: nil} = state) do
    {:noreply, %{state | disconnected_at: System.monotonic_time(:millisecond)}}
  end

  def handle_cast(:client_gone, state), do: {:noreply, state}

  @impl true
  def handle_info(:check_heartbeat, %{connected: false} = state) do
    # Startup grace: never shut down before the first heartbeat ever arrives.
    {:noreply, rearm(state)}
  end

  def handle_info(:check_heartbeat, state) do
    now = System.monotonic_time(:millisecond)
    late = now - state.next_check
    elapsed = now - state.last_heartbeat

    cond do
      late > state.stall_grace ->
        Logger.info(
          "[Codrift.ShutdownManager] check ran #{late}ms late — process was frozen, " <>
            "resetting the heartbeat baseline"
        )

        {:noreply,
         rearm(%{state | last_heartbeat: now, disconnected_at: state.disconnected_at && now})}

      state.disconnected_at && now - state.disconnected_at > state.reconnect_grace ->
        Logger.warning(
          "[Codrift.ShutdownManager] heartbeat socket closed and no reconnect in " <>
            "#{now - state.disconnected_at}ms — window gone, stopping"
        )

        initiate_shutdown(state)

      elapsed > state.timeout ->
        Logger.warning(
          "[Codrift.ShutdownManager] heartbeat lost (#{elapsed}ms) — window gone, stopping"
        )

        initiate_shutdown(state)

      true ->
        {:noreply, rearm(state)}
    end
  end

  def handle_info(:execute_shutdown, state) do
    Logger.info("[Codrift.ShutdownManager] stopping application")
    state.on_stop.()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[Codrift.ShutdownManager] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_socket)
    cleanup_socket(state.socket_path)
    :ok
  end

  defp setting(opts, key, env_key, default),
    do: opts[key] || Application.get_env(:ex_tauri, env_key, default)

  defp rearm(state), do: %{state | next_check: schedule_check(state.interval)}

  # Returns the moment the check is due, which is what makes a late one — a
  # frozen VM — detectable when it finally runs.
  defp schedule_check(interval) do
    Process.send_after(self(), :check_heartbeat, interval)
    System.monotonic_time(:millisecond) + interval
  end

  # Mirrors ExTauri.Paths.sanitize_name/1 so the socket path matches main.rs.
  defp sanitize_name(name) do
    name
    |> String.replace(~r/[\/\\]/, "")
    |> String.replace("..", "")
    |> String.replace(" ", "_")
    |> String.replace(~r/[^a-zA-Z0-9_\-]/, "")
    |> String.downcase()
  end

  defp cleanup_socket(socket_path) do
    File.rm(socket_path)
    :ok
  end

  # Only unlink a socket nobody is listening on. The old unconditional `File.rm`
  # meant a second sidecar booting (or dying seconds later, running `terminate`)
  # deleted the *live* instance's socket file. The live listener survives but
  # becomes unreachable, so its Tauri shell can never reconnect — and since its
  # ShutdownManager only acts on a heartbeat that stops *after* one arrived, that
  # backend stays alive forever holding :43117. That is how a sidecar from a
  # previous version was still squatting on the port days later.
  defp remove_stale_socket(socket_path) do
    if File.exists?(socket_path) do
      case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], 500) do
        {:ok, socket} ->
          :gen_tcp.close(socket)

          Logger.warning(
            "[Codrift.ShutdownManager] #{socket_path} has a live listener — another Codrift " <>
              "backend is already running. Leaving its socket alone."
          )

        {:error, _} ->
          File.rm(socket_path)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # The acceptor task accepts AND reads in the same process. recv MUST run in the
  # process that accepted: calling it from a separately spawned process returns
  # {:error, :closed} on a passive socket, so the heartbeat is never read and
  # `connected` never flips (this was the upstream bug). The Rust shell makes one
  # connection at a time and reconnects on drop, so handling them sequentially is
  # enough; after a connection ends we report it and accept the next one.
  defp accept_loop(listen_socket, manager) do
    case :gen_tcp.accept(listen_socket, 1000) do
      {:ok, client} ->
        recv_loop(client, manager)
        GenServer.cast(manager, :client_gone)
        accept_loop(listen_socket, manager)

      {:error, :timeout} ->
        accept_loop(listen_socket, manager)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("[Codrift.ShutdownManager] accept error: #{inspect(reason)}")
    end
  end

  defp recv_loop(client, manager) do
    case :gen_tcp.recv(client, 0) do
      {:ok, _data} ->
        GenServer.cast(manager, :heartbeat)
        recv_loop(client, manager)

      {:error, _reason} ->
        :gen_tcp.close(client)
    end
  end

  defp initiate_shutdown(%{shutdown_initiated: true} = state), do: {:noreply, state}

  defp initiate_shutdown(state) do
    Process.send_after(self(), :execute_shutdown, 100)
    {:noreply, %{state | shutdown_initiated: true}}
  end
end

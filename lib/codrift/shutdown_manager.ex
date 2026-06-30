defmodule Codrift.ShutdownManager do
  @moduledoc """
  Heartbeat-based shutdown for the Tauri desktop sidecar.

  The Rust shell connects to a Unix domain socket and writes a byte every 100ms;
  if the bytes stop, the window is gone (force-quit / crash) and this backend
  should stop itself too.

  Drop-in replacement for `ExTauri.ShutdownManager` with one correctness fix: the
  timeout is only enforced **after the first heartbeat is received**. The upstream
  version arms the 1500ms timeout at `init`, so a slow boot — the chain of this
  process starting, Bandit binding `:7437`, the Rust shell polling and detecting
  the port, connecting the socket, then sending the first byte — that exceeds the
  timeout makes the backend `System.stop/0` itself mid-startup, leaving the window
  pointed at a dead server (`ERR_CONNECTION_REFUSED`). Normal exits are already
  handled by the Rust shell (SIGTERM on window close / ExitRequested), so a state
  where no heartbeat has *ever* arrived must never trigger shutdown.
  """

  use GenServer
  require Logger

  @default_heartbeat_interval 500
  @default_heartbeat_timeout 1500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    interval = Application.get_env(:ex_tauri, :heartbeat_interval, @default_heartbeat_interval)
    timeout = Application.get_env(:ex_tauri, :heartbeat_timeout, @default_heartbeat_timeout)

    # Socket name mirrors what the Rust shell connects to: ExTauri's installer
    # sanitises the app name into main.rs (here "Codrift" -> "codrift"). Inlined
    # rather than calling ExTauri.Paths so this carries no runtime dep on ex_tauri.
    app_name = Application.get_env(:ex_tauri, :app_name, "Codrift")

    socket_path =
      Path.join(System.tmp_dir!(), "tauri_heartbeat_#{sanitize_name(app_name)}.sock")

    cleanup_socket(socket_path)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, socket_path}},
        {:active, false},
        {:reuseaddr, true}
      ])

    File.chmod(socket_path, 0o600)
    Task.Supervisor.start_child(Codrift.TaskSupervisor, fn -> accept_loop(listen_socket) end)
    schedule_check(interval)

    Logger.info("[Codrift.ShutdownManager] heartbeat monitoring on #{socket_path}")

    {:ok,
     %{
       listen_socket: listen_socket,
       socket_path: socket_path,
       last_heartbeat: System.monotonic_time(:millisecond),
       # Stays false until the Rust shell has connected at least once. While
       # false, a timeout is the still-booting case, not a lost window.
       connected: false,
       shutdown_initiated: false,
       interval: interval,
       timeout: timeout
     }}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    {:noreply, %{state | last_heartbeat: System.monotonic_time(:millisecond), connected: true}}
  end

  @impl true
  def handle_info(:check_heartbeat, %{connected: false} = state) do
    # Startup grace: never shut down before the first heartbeat ever arrives.
    schedule_check(state.interval)
    {:noreply, state}
  end

  def handle_info(:check_heartbeat, state) do
    elapsed = System.monotonic_time(:millisecond) - state.last_heartbeat

    if elapsed > state.timeout do
      Logger.warning(
        "[Codrift.ShutdownManager] heartbeat lost (#{elapsed}ms) — window gone, stopping"
      )

      initiate_shutdown(state)
    else
      schedule_check(state.interval)
      {:noreply, state}
    end
  end

  def handle_info(:execute_shutdown, state) do
    Logger.info("[Codrift.ShutdownManager] stopping application")
    System.stop(0)
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

  defp schedule_check(interval), do: Process.send_after(self(), :check_heartbeat, interval)

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

  # The acceptor task accepts AND reads in the same process. recv MUST run in the
  # process that accepted: calling it from a separately spawned process returns
  # {:error, :closed} on a passive socket, so the heartbeat is never read and
  # `connected` never flips (this was the upstream bug). The Rust shell makes one
  # connection at a time and reconnects on drop, so handling them sequentially is
  # enough; after a connection ends we loop back to accept the next one.
  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket, 1000) do
      {:ok, client} ->
        recv_loop(client)
        accept_loop(listen_socket)

      {:error, :timeout} ->
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("[Codrift.ShutdownManager] accept error: #{inspect(reason)}")
    end
  end

  defp recv_loop(client) do
    case :gen_tcp.recv(client, 0) do
      {:ok, _data} ->
        GenServer.cast(__MODULE__, :heartbeat)
        recv_loop(client)

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

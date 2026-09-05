defmodule Codrift.ShutdownManagerTest do
  # Drives real timers and a real Unix socket, so the timings are short but the
  # paths are the production ones. `on_stop` is the only injection: the real one
  # is `System.stop/0`, which would take the test VM with it.
  use ExUnit.Case, async: false

  alias Codrift.ShutdownManager

  setup do
    test = self()
    app = "codrift_test_#{System.unique_integer([:positive])}"
    name = :"shutdown_manager_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {ShutdownManager,
         name: name,
         app_name: app,
         interval: 50,
         timeout: 300,
         stall_grace: 100,
         reconnect_grace: 150,
         on_stop: fn -> send(test, :stopped) end},
        id: name
      )

    %{manager: pid, socket_path: Path.join(System.tmp_dir!(), "tauri_heartbeat_#{app}.sock")}
  end

  defp connect(socket_path) do
    {:ok, socket} = :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false])
    socket
  end

  defp beat(socket), do: :ok = :gen_tcp.send(socket, "h")

  defp pump(socket) do
    spawn_link(fn ->
      Stream.repeatedly(fn ->
        :gen_tcp.send(socket, "h")
        Process.sleep(25)
      end)
      |> Stream.run()
    end)
  end

  test "never stops before the first heartbeat arrives" do
    # Boot can outlast the timeout: the shell has to poll :43117, connect and
    # write before anything is heard from it.
    refute_receive :stopped, 500
  end

  test "stops when the shell stops writing", %{socket_path: path} do
    socket = connect(path)
    beat(socket)

    assert_receive :stopped, 1000
  end

  test "stops when the connection closes and nothing reconnects", %{socket_path: path} do
    socket = connect(path)
    beat(socket)
    :gen_tcp.close(socket)

    # Faster than the byte timeout: a closed socket is a dead process, not a gap.
    assert_receive :stopped, 500
  end

  test "survives the process being frozen for longer than the timeout", %{
    manager: manager,
    socket_path: path
  } do
    socket = connect(path)
    beat(socket)

    # What a laptop sleeping does: this process stops running while the clock
    # keeps going, and nothing is written for the whole gap. The check that runs
    # on the other side of it measures a gap far past the timeout.
    :sys.suspend(manager)
    Process.sleep(400)
    :sys.resume(manager)

    pump(socket)
    refute_receive :stopped, 400
  end

  describe "the orphan check" do
    # The one case the heartbeat cannot see: it never started. Without this a
    # sidecar whose shell died before it could connect sat on :43117 forever —
    # seven were found running at once, going back three versions.
    test "stops a sidecar that was never heartbeated and has lost its parent" do
      start_manager(orphan_grace: 0, orphan_check: fn -> true end)

      assert_receive :stopped, 1000
    end

    test "leaves a slow boot alone while the parent is still there" do
      start_manager(orphan_grace: 0, orphan_check: fn -> false end)

      refute_receive :stopped, 500
    end

    test "does not run before the grace has passed" do
      test = self()

      start_manager(
        orphan_grace: 10_000,
        orphan_check: fn ->
          send(test, :checked)
          true
        end
      )

      refute_receive :checked, 300
      refute_receive :stopped, 100
    end

    test "ignores a lost parent once the shell has spoken" do
      # A connected shell is the heartbeat's business from then on, and only a
      # sidecar that was never spoken to can be judged by its parent alone.
      %{socket_path: path} = start_manager(orphan_grace: 300, orphan_check: fn -> true end)

      socket = connect(path)
      pump(socket)

      refute_receive :stopped, 400
    end
  end

  defp start_manager(opts) do
    test = self()
    app = "codrift_test_#{System.unique_integer([:positive])}"
    name = :"shutdown_manager_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      app_name: app,
      interval: 50,
      timeout: 100_000,
      stall_grace: 100_000,
      reconnect_grace: 100_000,
      on_stop: fn -> send(test, :stopped) end
    ]

    start_supervised!({ShutdownManager, Keyword.merge(defaults, opts)}, id: name)

    %{socket_path: Path.join(System.tmp_dir!(), "tauri_heartbeat_#{app}.sock")}
  end
end

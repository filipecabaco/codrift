defmodule Codrift.SidecarTest do
  # Signals real OS processes, so it must not race another test's port probe.
  use ExUnit.Case, async: false

  alias Codrift.Sidecar

  # The exact shape `ps -o command=` prints for a shipped sidecar on each
  # platform. Burrito unpacks under Application Support on macOS and
  # ~/.local/share on Linux; both go through the same `.burrito/desktop_` dir.
  @macos "/Users/x/Library/Application Support/.burrito/desktop_erts-15.2.7.10_0.2.8/erts-15.2.7.10/bin/beam.smp -- -root ..."
  @linux "/home/x/.local/share/.burrito/desktop_erts-15.2.7.10_0.2.10/erts-15.2.7.10/bin/beam.smp -- -root ..."

  describe "packaged_sidecar?/1" do
    test "recognises a shipped sidecar on both platforms" do
      assert Sidecar.packaged_sidecar?(@macos)
      assert Sidecar.packaged_sidecar?(@linux)
    end

    test "ignores the release's own helper processes" do
      # Same unpack directory, not the thing holding the port. Killing these
      # would tear the ports out from under a perfectly healthy sidecar.
      refute Sidecar.packaged_sidecar?(
               "/Users/x/Library/Application Support/.burrito/desktop_erts-15.2.7.10_0.2.8/erts-15.2.7.10/bin/erl_child_setup 1024"
             )
    end

    test "ignores a CLI invocation of the same release" do
      # Burrito puts a subcommand's arguments after `-extra`. `codrift <cmd>`
      # shares the unpack directory and the payload with the sidecar, but it
      # never had a window and is regularly a child of init.
      refute Sidecar.packaged_sidecar?(@macos <> " -- -- -extra mcp")
      assert Sidecar.packaged_sidecar?(@macos <> " -- -- -extra")
    end

    test "ignores a development server" do
      # `mix francis.server` is regularly a child of init and perfectly healthy,
      # so only the packaged path may ever be eligible for eviction.
      refute Sidecar.packaged_sidecar?("/opt/erlang/erts-15.2/bin/beam.smp -- -root /opt/erlang")
      refute Sidecar.packaged_sidecar?(nil)
    end
  end

  describe "orphan_sidecar?/1" do
    test "never nominates the current process" do
      # It has a live parent and is not packaged, but the identity check has to
      # hold on its own: a sidecar must never signal itself.
      assert {pid, _} = Integer.parse(System.pid())
      refute Sidecar.orphan_sidecar?(pid)
    end

    test "is false for a pid that does not exist" do
      refute Sidecar.orphan_sidecar?(999_999)
    end
  end

  describe "orphan?/0" do
    test "is false while the test VM still has its parent" do
      refute Sidecar.orphan?()
    end
  end

  describe "reclaim_port/1" do
    test "reports a port nobody holds as free" do
      assert :free = Sidecar.reclaim_port(free_port())
    end

    test "refuses to evict a listener that is not an abandoned sidecar" do
      port = free_port()

      {:ok, socket} =
        :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      on_exit(fn -> :gen_tcp.close(socket) end)

      assert {:blocked, reason} = Sidecar.reclaim_port(port)
      assert reason =~ "#{port}"
    end
  end

  describe "identify/1" do
    setup do
      # A real unpack directory, because that is the only thing separating our
      # sidecar from another app's: `desktop` is ex_tauri's default release name
      # and every app generated with it lands in this same directory.
      root =
        Path.join([
          System.tmp_dir!(),
          "codrift sidecar test #{System.unique_integer([:positive])}",
          ".burrito",
          "desktop_erts-15.2.7.10_0.6.0"
        ])

      on_exit(fn -> File.rm_rf(Path.dirname(Path.dirname(root))) end)

      %{root: root}
    end

    test "recognises our own release", %{root: root} do
      unpack(root, "codrift-0.2.10")

      assert :ours = Sidecar.identify(command_in(root))
    end

    test "refuses to claim another Burrito app's sidecar", %{root: root} do
      # The one that actually happened: four Vitro sidecars, versions 0.3.0
      # through 0.6.0, in `.burrito/desktop_*` on this machine. Reaping them
      # would have SIGTERMed a running app that is not ours.
      unpack(root, "vitro-0.6.0")

      assert :foreign = Sidecar.identify(command_in(root))
    end

    test "says it cannot tell when the unpack directory is gone", %{root: root} do
      # An upgrade that cleans up after itself leaves the old sidecar running
      # from a path that no longer exists. That process is the whole reason this
      # module exists, so it must not read as another app's.
      assert :unknown = Sidecar.identify(command_in(root))
    end

    test "reads the root from argv[0], not from the -root that repeats later" do
      # Both paths are on every sidecar's command line. A greedy match takes the
      # last one, which on a machine with two Burrito apps is how ours gets
      # identified as theirs.
      ours =
        Path.join([
          System.tmp_dir!(),
          "codrift argv0 #{System.unique_integer([:positive])}",
          ".burrito",
          "desktop_erts-15.2.7.10_0.6.0"
        ])

      theirs = String.replace(ours, "codrift argv0", "other argv0")

      on_exit(fn ->
        File.rm_rf(Path.dirname(Path.dirname(ours)))
        File.rm_rf(Path.dirname(Path.dirname(theirs)))
      end)

      unpack(ours, "codrift-0.2.10")
      unpack(theirs, "vitro-0.6.0")

      assert :ours =
               Sidecar.identify(
                 "#{ours}/erts-15.2.7.10/bin/beam.smp -- -root #{theirs} -progname erl"
               )
    end

    test "cannot tell for anything that is not a packaged sidecar" do
      assert :unknown = Sidecar.identify(nil)

      assert :unknown =
               Sidecar.identify("/opt/erlang/erts-15.2/bin/beam.smp -- -root /opt/erlang")
    end
  end

  # `lib/<app>-<vsn>` is what Burrito unpacks and what identify/1 reads.
  defp unpack(root, app), do: File.mkdir_p!(Path.join([root, "lib", app]))

  # The shape `ps -o command=` prints: the emulator inside the unpack root, then
  # the same root again behind `-root`.
  defp command_in(root),
    do: "#{root}/erts-15.2.7.10/bin/beam.smp -- -root #{root} -progname erl"

  # Bind on 0 to have the OS name a port, then release it. Racy in principle,
  # but nothing else in this suite binds a fixed port.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

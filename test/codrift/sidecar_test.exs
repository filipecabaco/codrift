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

  # Bind on 0 to have the OS name a port, then release it. Racy in principle,
  # but nothing else in this suite binds a fixed port.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

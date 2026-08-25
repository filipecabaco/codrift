defmodule Codrift.CLI.MCPStatusTest do
  @moduledoc """
  `codrift mcp status` driven against a real `claude` executable on PATH.

  No stub: the fixture is a shell script that prints what the real command
  prints and exits with the code it would exit with, so `System.find_executable/1`,
  `System.cmd/3`, the env passed to it and the exit-code branch are all the ones
  that run in production. The output format of another program is exactly the
  kind of thing a stub gets to be wrong about for free.

  The reason this command exists is the failure it reports: a server that every
  client hangs on used to report itself as installed and fine, because the
  status line was collapsed to "registered". So what is asserted is that
  Claude's own line survives verbatim.

  `install` is deliberately not driven here — it writes into `~/.gemini`,
  `~/.cursor` and `~/.config/opencode`, which belong to the person running the
  tests.

  Not `async`: mutates PATH, which is process-wide.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Codrift.CLI.MCP

  @moduletag :tmp_dir

  # Nothing listens here, so `verify_endpoint/2` takes its connection-refused
  # branch instead of reaching the user's actually-running Codrift on 43117.
  @dead_port "--port=45999"

  setup %{tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    previous_data = Application.get_env(:codrift, :data_dir)
    Application.put_env(:codrift, :data_dir, Path.join(tmp_dir, "data"))
    File.mkdir_p!(Path.join(tmp_dir, "data"))
    on_exit(fn -> Application.put_env(:codrift, :data_dir, previous_data) end)

    {:ok, bin: bin}
  end

  # A real executable, not a stub: `claude` here is a shell script that behaves
  # the way the real one does for `mcp list`.
  defp fake_claude!(bin, body) do
    path = Path.join(bin, "claude")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp status(args \\ []) do
    capture_io(fn -> MCP.run(["status", @dead_port | args]) end)
  end

  test "reports Claude's own listing line verbatim, connection state included",
       %{bin: bin} do
    fake_claude!(bin, """
    echo "Checking MCP server health..."
    echo ""
    echo "  codrift: http://localhost:43117/mcp - ✓ Connected"
    """)

    output = status()

    assert output =~ "default: codrift: http://localhost:43117/mcp - ✓ Connected"
  end

  test "a listing that shows the server as failing says so, rather than 'registered'",
       %{bin: bin} do
    # The bug this command was rewritten for: a server every client hung on
    # still reported itself as installed and fine.
    fake_claude!(bin, """
    echo "  codrift: http://localhost:43117/mcp - ✗ Failed to connect"
    """)

    assert status() =~ "✗ Failed to connect"
  end

  test "a listing without our server reports it missing, with the command to fix it",
       %{bin: bin} do
    fake_claude!(bin, """
    echo "  something-else: https://example.test/mcp - ✓ Connected"
    """)

    output = status()

    assert output =~ "[missing]"
    assert output =~ "codrift mcp install"
  end

  test "a non-zero exit is reported with the code and the output", %{bin: bin} do
    fake_claude!(bin, """
    echo "not logged in" >&2
    exit 3
    """)

    output = status()

    assert output =~ "[error]"
    assert output =~ "exited 3"
    assert output =~ "not logged in"
  end

  test "with claude absent from PATH, it says so instead of failing", %{tmp_dir: tmp_dir} do
    # An empty PATH is the honest version of "the tool is not installed".
    original = System.get_env("PATH")
    System.put_env("PATH", Path.join(tmp_dir, "empty"))
    on_exit(fn -> System.put_env("PATH", original) end)

    assert status() =~ "claude not found in PATH"
  end

  test "an endpoint with nothing listening is reported as refused, not as a crash",
       %{bin: bin} do
    fake_claude!(bin, ~s(echo "  codrift: http://localhost:45999/mcp - ✓ Connected"\n))

    output = status()

    assert output =~ "refused" or output =~ "could not reach"
  end

  describe "profiles" do
    test "a profile that settings.json does not have is named as missing", %{bin: bin} do
      fake_claude!(bin, ~s(echo "  codrift: http://localhost:1/mcp"\n))

      assert status(["--profile=no-such-profile"]) =~
               "no-such-profile: not found in settings.json"
    end

    test "a profile with its own config dir gets its own line", %{bin: bin} do
      # The fake echoes CLAUDE_CONFIG_DIR so the assertion is that the env
      # really reached the subprocess, not merely that a line was printed.
      fake_claude!(bin, ~s(echo "  codrift: dir=$CLAUDE_CONFIG_DIR"\n))

      Codrift.Config.Settings.put_profile("work", %{
        adapter: "claude",
        env: %{"CLAUDE_CONFIG_DIR" => "~/.claude-work"}
      })

      output = status(["--profile=work"])

      assert output =~ "work: codrift: dir=" <> Path.expand("~/.claude-work")
    end

    test "a profile with no config dir of its own says it shares the default", %{bin: bin} do
      fake_claude!(bin, ~s(echo "  codrift: http://localhost:1/mcp"\n))

      Codrift.Config.Settings.put_profile("plain", %{adapter: "claude", env: %{}})

      assert status(["--profile=plain"]) =~ "plain: shares the default config"
    end

    test "--all-profiles with none configured says so", %{bin: bin} do
      fake_claude!(bin, ~s(echo "  codrift: http://localhost:1/mcp"\n))

      assert status(["--all-profiles"]) =~ "No launch profiles configured"
    end
  end
end

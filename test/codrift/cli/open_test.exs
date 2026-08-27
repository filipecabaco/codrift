defmodule Codrift.CLI.OpenTest do
  @moduledoc """
  Coverage for `codrift open`, the shell-facing half of the `open_file` MCP tool.

  The request path itself is covered by `Codrift.CoreOpenFileTest`; what is
  worth pinning here is the argv contract, because a flag that is silently
  dropped becomes a pin filed under the wrong name with no reason attached.

  The failure paths are deliberately not exercised: `fail/1` calls
  `System.halt/1`, which would take the test VM with it — the same reason the
  other CLI suites only drive their non-halting paths.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Codrift.CLI.Main
  alias Codrift.CLI.Open

  describe "args/3" do
    test "carries the initiative and the file on their own" do
      assert Open.args("init-1", "/tmp/project/router.ex", []) ==
               %{"initiative_id" => "init-1", "path" => "/tmp/project/router.ex"}
    end

    # A relative path means "relative to the shell I typed this in", and the
    # app's working directory is not that shell's — so it cannot be sent as-is.
    test "expands a relative path against the caller's directory" do
      %{"path" => path} = Open.args("init-1", "lib/router.ex", [])

      assert path == Path.expand("lib/router.ex")
      assert Path.type(path) == :absolute
    end

    test "expands a ~ path" do
      %{"path" => path} = Open.args("init-1", "~/code/router.ex", [])

      assert path == Path.expand("~/code/router.ex")
      refute String.starts_with?(path, "~")
    end

    # Absent flags are omitted rather than sent as nil, so the server's own
    # naming (the file's basename) still applies.
    test "omits flags that were not passed" do
      args = Open.args("init-1", "/tmp/router.ex", ["--reason=because"])

      refute Map.has_key?(args, "name")
      assert args["reason"] == "because"
    end

    test "collects every flag" do
      args =
        Open.args("init-1", "/tmp/router.ex", [
          "--name=the-router.ex",
          "--reason=where the bug lives"
        ])

      assert args == %{
               "initiative_id" => "init-1",
               "path" => "/tmp/router.ex",
               "name" => "the-router.ex",
               "reason" => "where the bug lives"
             }
    end

    # A reason is prose, and prose is full of the characters a naive split eats.
    test "keeps a reason containing = and quotes intact" do
      args = Open.args("init-1", "/tmp/router.ex", [~s(--reason=a=b, the "real" one)])

      assert args["reason"] == ~s(a=b, the "real" one)
    end

    test "ignores flags it does not know" do
      args = Open.args("init-1", "/tmp/router.ex", ["--nonsense=1", "--name=x.ex"])

      assert args == %{
               "initiative_id" => "init-1",
               "path" => "/tmp/router.ex",
               "name" => "x.ex"
             }
    end
  end

  describe "usage" do
    test "names the command and its arguments" do
      output = capture_io(fn -> Open.run([]) end)

      assert output =~ "codrift open <initiative_id> <path>"
      assert output =~ "--reason"
    end

    # Both are things a caller finds out the hard way otherwise.
    test "says where the path must live and that the app must be running" do
      output = capture_io(fn -> Open.run([]) end)

      assert output =~ "inside one of the initiative's directories"
      assert output =~ "desktop app must be running"
    end

    test "is what a call with no file gets" do
      assert capture_io(fn -> Open.run(["init-1"]) end) =~ "codrift open <initiative_id> <path>"
    end

    test "is reachable through the top-level dispatcher" do
      assert capture_io(fn -> Main.run(["open"]) end) =~ "codrift open <initiative_id> <path>"
    end
  end
end

defmodule Codrift.CLI.PaneTest do
  @moduledoc """
  Coverage for `codrift pane`, the shell-facing half of the handoff pair.

  It exists for the case where the MCP server is not registered for the config
  directory an agent happens to be running under, so its job is to reach the
  desktop app over the local HTTP API. The request path itself is covered by
  `Codrift.CoreHandoffTest`; what is worth pinning here is the argv contract,
  because a flag that is silently dropped becomes a terminal that opens in the
  wrong directory with nothing typed in it.

  The failure paths are deliberately not exercised: `fail/1` calls
  `System.halt/1`, which would take the test VM with it — the same reason the
  other CLI suites only drive their non-halting paths.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Codrift.CLI.Main
  alias Codrift.CLI.Pane

  describe "terminal_args/2" do
    test "carries the initiative on its own" do
      assert Pane.terminal_args("init-1", []) == %{"initiative_id" => "init-1"}
    end

    # Absent flags are omitted rather than sent as nil, so the server's own
    # defaults still apply — the scratchpad directory, and no prefill at all.
    test "omits flags that were not passed" do
      args = Pane.terminal_args("init-1", ["--reason=because"])

      refute Map.has_key?(args, "dir")
      refute Map.has_key?(args, "command")
      assert args["reason"] == "because"
    end

    test "collects every flag" do
      args =
        Pane.terminal_args("init-1", [
          "--dir=/tmp/project",
          "--command=git status",
          "--reason=take a look"
        ])

      assert args == %{
               "initiative_id" => "init-1",
               "dir" => "/tmp/project",
               "command" => "git status",
               "reason" => "take a look"
             }
    end

    # A commit message is the whole point of the tool and is full of the
    # characters a naive split would eat.
    test "keeps a command containing = and quotes intact" do
      args = Pane.terminal_args("init-1", [~s(--command=git commit -m "fix: a=b, c=d")])

      assert args["command"] == ~s(git commit -m "fix: a=b, c=d")
    end

    test "ignores flags it does not know" do
      args = Pane.terminal_args("init-1", ["--nonsense=1", "--dir=/tmp"])

      assert args == %{"initiative_id" => "init-1", "dir" => "/tmp"}
    end
  end

  describe "focus_args/2" do
    test "carries the agent, with and without a reason" do
      assert Pane.focus_args("a1", []) == %{"agent_id" => "a1"}

      assert Pane.focus_args("a1", ["--reason=come back"]) ==
               %{"agent_id" => "a1", "reason" => "come back"}
    end
  end

  describe "usage" do
    test "names both subcommands" do
      output = capture_io(fn -> Pane.run([]) end)

      assert output =~ "codrift pane terminal"
      assert output =~ "codrift pane focus"
    end

    # The one thing a reader must not miss: the drafted command is not executed.
    test "says the drafted command is not run" do
      output = capture_io(fn -> Pane.run([]) end)

      assert output =~ "NOT RUN"
    end

    test "is what an unknown subcommand gets" do
      assert capture_io(fn -> Pane.run(["wat"]) end) =~ "codrift pane terminal"
    end

    test "is reachable through the top-level dispatcher" do
      assert capture_io(fn -> Main.run(["pane"]) end) =~ "codrift pane terminal"
    end
  end
end

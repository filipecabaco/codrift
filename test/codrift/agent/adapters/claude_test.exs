defmodule Codrift.Agent.Adapters.ClaudeTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Agent.Adapters.Claude

  test "mode/0 is :pty — persistent session with real terminal" do
    assert :pty = Claude.mode()
  end

  test "args/2 returns empty list when no context_dir" do
    assert [] = Claude.args("/some/dir", [])
  end

  test "args/2 returns --add-dir when context_dir present" do
    assert ["--add-dir", "/ctx"] = Claude.args("/some/dir", context_dir: "/ctx")
  end

  test "args_continue/1 returns empty list (PTY keeps its own session)" do
    assert [] = Claude.args_continue("/some/dir")
  end

  test "env/1 sets TERM for color support" do
    env = Claude.env("/some/dir")
    assert is_list(env)
    assert {"TERM", "xterm-256color"} in env
  end

  test "parse_status detects awaiting_input from prompt" do
    assert :awaiting_input = Claude.parse_status("some output\n> ")
  end

  test "parse_status detects running" do
    assert :running = Claude.parse_status("Running some tool...")
  end

  # A working Claude Code repaints its prompt box every frame, so a frame that
  # carries the ❯ says nothing about readiness on its own. Reading it as
  # `:awaiting_input` told an orchestrator the agent was free the entire time it
  # was busy.
  test "a frame drawn while working is :running even though it carries the prompt char" do
    frame = "\e[2J❯ Verification task\n✻ Reticulating… ⏵⏵ esc to interrupt"
    assert :running = Claude.parse_status(frame)
  end

  test "the same frame without the interrupt hint is :awaiting_input" do
    assert :awaiting_input = Claude.parse_status("\e[2J❯ Cogitated for 1s · done")
  end

  test "parse_status returns nil for unrecognized output" do
    assert nil == Claude.parse_status("just some text")
  end
end

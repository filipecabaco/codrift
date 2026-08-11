defmodule Codrift.Agent.Adapters.CursorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Agent.Adapters.Cursor

  test "mode/0 is :pty — cursor-agent only starts its TUI with a terminal" do
    assert :pty = Cursor.mode()
  end

  test "args/2 and args_continue/1 pass no flags — the TUI owns its own chat" do
    assert [] = Cursor.args("/some/dir", context_dir: "/ctx")
    assert [] = Cursor.args_continue("/some/dir")
  end

  test "env/1 sets TERM for color support" do
    assert {"TERM", "xterm-256color"} in Cursor.env("/some/dir")
  end

  test "sessions are not persistable — chat IDs are minted by cursor-agent" do
    refute Cursor.session_persistable?()
  end

  test "tui?/0 is true so output replays from the last screen clear" do
    assert Cursor.tui?()
  end

  test "parse_status detects the TUI's first full frame" do
    assert :awaiting_input = Cursor.parse_status("\e[2Jsome frame")
  end

  test "parse_status detects awaiting_input from the prompt" do
    assert :awaiting_input = Cursor.parse_status("some output\n> ")
  end

  test "parse_status returns nil for unrecognized output" do
    assert nil == Cursor.parse_status("just some text")
  end

  test "the adapter resolves from its name and is in the registry" do
    assert Cursor == Codrift.Agent.module_from_name("cursor")
  end
end

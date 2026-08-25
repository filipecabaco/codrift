defmodule Codrift.Agent.Adapters.PtyAdaptersTest do
  @moduledoc """
  The four adapters that carry no per-tool logic beyond "start the CLI and watch
  for its prompt": codex, gemini, opencode and copilot.

  They are tested as a table rather than four near-identical files because the
  thing worth pinning is the *contract* — a wrong `mode/0` starts a TUI with no
  terminal and it hangs; a `parse_status/1` that never returns `:awaiting_input`
  leaves an agent that is waiting on the user looking idle forever.

  Claude and Cursor have their own files: they carry real behaviour (session
  resumption, flags) that does not fit a table.
  """
  use ExUnit.Case, async: true

  alias Codrift.Agent.Adapters.{Codex, Copilot, Gemini, Opencode}

  # {name, module, mode, args, tui?, env, prompt marker or nil}
  @adapters [
    {"codex", Codex, :pty, [], true, true, "> "},
    {"gemini", Gemini, :pty, [], true, true, "> "},
    {"opencode", Opencode, :pty, [], true, true, nil},
    {"copilot", Copilot, :interactive, ["copilot", "suggest"], false, false, "? "}
  ]

  for {name, module, mode, args, tui, colour_env, prompt} <- @adapters do
    describe "#{name}" do
      test "resolves from its name and reports that name back" do
        assert unquote(module) == Codrift.Agent.module_from_name(unquote(name))
        assert unquote(name) == Codrift.Agent.adapter_name(unquote(module))
      end

      test "mode/0 decides whether it gets a terminal" do
        assert unquote(mode) == unquote(module).mode()
      end

      test "args/2 and args_continue/1 agree — there is no resume flag to add" do
        assert unquote(args) == unquote(module).args("/some/dir", context_dir: "/ctx")
        assert unquote(args) == unquote(module).args_continue("/some/dir")
      end

      test "sessions are not persistable, so the UI never offers to resume one" do
        refute unquote(module).session_persistable?()
      end

      test "tui?/0 decides whether output replays from the last screen clear" do
        assert unquote(tui) == unquote(module).tui?()
      end

      # Branched here, at macro-expansion time, rather than inside one test with
      # an `if`: the dead half would still be compiled, against a type the
      # compiler can already prove impossible.
      if colour_env do
        test "env/1 asks for colour, since this one draws a TUI" do
          env = unquote(module).env("/some/dir")
          assert {"TERM", "xterm-256color"} in env
          assert {"COLORTERM", "truecolor"} in env
        end
      else
        test "env/1 adds nothing — it runs as a plain line-oriented command" do
          assert [] == unquote(module).env("/some/dir")
        end
      end

      test "parse_status sees the first full frame" do
        assert :awaiting_input = unquote(module).parse_status("\e[2Jsome frame")
      end

      test "parse_status returns nil for output that says nothing about readiness" do
        assert nil == unquote(module).parse_status("just some text")
      end

      if prompt do
        test "parse_status sees the prompt" do
          assert :awaiting_input =
                   unquote(module).parse_status("some output\n" <> unquote(prompt))
        end
      end

      test "available?/0 answers without raising, and cmd/0 says what is missing" do
        available = unquote(module).available?()
        assert is_boolean(available)

        # `cmd/0` resolves against PATH, so which branch runs depends on the
        # machine. Both are valid; what must never happen is a bare
        # `FunctionClauseError` or a nil command handed to the port.
        if available do
          assert is_binary(unquote(module).cmd())
        else
          assert_raise RuntimeError, ~r/not found in PATH/, fn -> unquote(module).cmd() end
        end
      end
    end
  end
end

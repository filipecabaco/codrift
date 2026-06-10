defmodule Codrift.Agent do
  @moduledoc """
  Behaviour for AI coding agent CLI adapters.

  ## Modes

  Adapters declare their invocation mode via `mode/0`:

  - `:pty` — a PTY is allocated via `erlexec` so the CLI gets a real
    terminal. ANSI colors, cursor movement, and interactive TUI features
    all work. Required for Claude Code which detects TTY presence.

  - `:interactive` — long-running process with plain pipes (no PTY). Text
    is sent to stdin. Suitable for CLIs that work without a TTY.

  - `:once` — a fresh process per message; text is a trailing CLI argument.
    Suitable for `claude --print --continue`.

  ## Implementing an adapter

      defmodule MyApp.Agent.Adapters.MyCLI do
        @behaviour Codrift.Agent

        @impl true
        def cmd, do: System.find_executable("mycli") || raise "mycli not found"

        @impl true
        def mode, do: :interactive

        @impl true
        def args(_dir), do: ["--flag"]

        @impl true
        def args_continue(dir), do: args(dir)

        @impl true
        def env(_dir), do: []

        @impl true
        def parse_status("prompt> " <> _), do: :awaiting_input
        def parse_status(_), do: nil
      end
  """

  @doc "Returns the absolute path to the CLI executable."
  @callback cmd() :: String.t()

  @doc "Returns the invocation mode. See module docs for the three modes."
  @callback mode() :: :pty | :interactive | :once

  @doc """
  Returns CLI arguments for the first invocation in the given directory.

  `opts` may contain:
  - `context_dir: path`   — absolute path to the initiative's context folder
  - `context_files: [path]` — list of absolute paths to context files
  - `session_id: uuid`    — Claude Code session UUID for `--resume`

  Adapters that understand initiative context should use these to inject context
  at startup via their native mechanism.
  """
  @callback args(dir :: String.t(), opts :: keyword()) :: [String.t()]

  @doc """
  Returns CLI arguments for continuation turns in `:once` mode.

  Called for the second and subsequent messages instead of `args/2`.
  Adapters in `:pty` / `:interactive` mode may return the same as `args/2`.
  """
  @callback args_continue(dir :: String.t()) :: [String.t()]

  @doc ~S[Returns additional environment variables as `{"KEY", "VALUE"}` tuples.]
  @callback env(dir :: String.t()) :: [{String.t(), String.t()}]

  @doc """
  Inspects a stdout chunk and infers the agent's current status.

  Return `:idle | :running | :awaiting_input`, or `nil` to leave unchanged.
  """
  @callback parse_status(output :: binary()) :: :idle | :running | :awaiting_input | nil

  @doc """
  Returns `true` when the adapter supports session persistence.

  Adapters that persist sessions (e.g. Claude Code via `--resume`) should
  return `true`. All others return `false`.
  """
  @callback session_persistable?() :: boolean()

  @doc """
  Returns `true` for full-screen TUI adapters (Ink, Bubble Tea) that require
  `chunks_from_last_clear` replay and a two-step PTY resize to force a repaint.
  Returns `false` for plain interactive CLIs and shell adapters.
  """
  @callback tui?() :: boolean()

  @doc ~S[Returns the human-readable adapter name (e.g. "claude", "codex", "terminal").]
  def adapter_name(module), do: module |> Module.split() |> List.last() |> String.downcase()

  @all_adapters [
    Codrift.Agent.Adapters.Claude,
    Codrift.Agent.Adapters.Codex,
    Codrift.Agent.Adapters.Opencode,
    Codrift.Agent.Adapters.Gemini,
    Codrift.Agent.Adapters.Copilot
  ]

  @doc "Returns all adapter modules whose CLI executable is present in PATH."
  def available_adapters, do: Enum.filter(@all_adapters, & &1.available?())

  @doc "Resolves an adapter name string back to its module. Returns `nil` if unknown."
  def module_from_name(name) do
    Enum.find(@all_adapters, fn mod -> adapter_name(mod) == name end)
  end
end

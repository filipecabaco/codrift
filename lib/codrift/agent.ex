defmodule Codrift.Agent do
  @moduledoc """
  Behaviour for AI coding agent CLI adapters.

  ## Modes

  Adapters declare their invocation mode via `mode/0`:

  - `:pty` — a PTY is allocated via `erlexec` so the CLI gets a real
    terminal. ANSI colors, cursor movement, and interactive TUI features
    all work. Required for Claude Code which detects TTY presence.

  - `:interactive` — long-running process with plain pipes (no PTY). Text
    is sent to stdin. Suitable for CLIs that work without a TTY (Aider).

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

  Adapters that understand initiative context (Claude, Aider) should use these to
  inject context at startup via their native mechanism (`--add-dir`, `--read`, etc.).
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

  @doc ~S[Returns the human-readable adapter name (e.g. "claude", "aider", "terminal").]
  def adapter_name(module), do: module |> Module.split() |> List.last() |> String.downcase()
end

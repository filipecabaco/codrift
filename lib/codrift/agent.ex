defmodule Codrift.Agent do
  @moduledoc """
  Behaviour for AI coding agent CLI adapters.

  ## Modes

  Adapters declare their invocation mode via the optional `mode/0` callback:

  - `:interactive` (default) — a single long-running process; text is sent to
    its stdin. Suitable for CLIs like Aider that keep an interactive session.

  - `:once` — a new OS process is spawned for every message. The text is
    passed as a trailing CLI argument. Continuation across turns is handled
    by `args_continue/1`. Suitable for Claude Code with `--print --continue`.

  ## Implementing an adapter

      defmodule MyApp.Agent.Adapters.MyCLI do
        @behaviour Codrift.Agent

        @impl true
        def cmd, do: System.find_executable("mycli") || raise "mycli not found"

        @impl true
        def args(_dir), do: ["--flag"]

        @impl true
        def env(_dir), do: []

        @impl true
        def parse_status("prompt> " <> _), do: :awaiting_input
        def parse_status(_), do: nil
      end
  """

  @doc "Returns the absolute path to the CLI executable."
  @callback cmd() :: String.t()

  @doc "Returns CLI arguments for the first invocation in the given directory."
  @callback args(dir :: String.t()) :: [String.t()]

  @doc "Returns additional environment variables as `{\"KEY\", \"VALUE\"}` tuples."
  @callback env(dir :: String.t()) :: [{String.t(), String.t()}]

  @doc """
  Inspects a chunk of stdout output and infers the agent's current status.

  Return `:idle | :running | :awaiting_input`, or `nil` to leave unchanged.
  """
  @callback parse_status(output :: binary()) :: :idle | :running | :awaiting_input | nil

  @doc """
  Returns the invocation mode for this adapter.

  - `:interactive` — one long-running process; text is piped to stdin.
    Suitable for CLIs like Aider that maintain an interactive session.
  - `:once` — a fresh process is spawned per message; text is appended
    as a trailing CLI argument. Suitable for `claude --print --continue`.
  """
  @callback mode() :: :interactive | :once

  @doc """
  Returns CLI arguments for continuation turns in `:once` mode.

  Called for the second and subsequent messages instead of `args/1`.
  Adapters in `:interactive` mode may return the same as `args/1`.
  """
  @callback args_continue(dir :: String.t()) :: [String.t()]
end

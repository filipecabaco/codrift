defmodule Codrift.Agent do
  @moduledoc """
  Behaviour for AI coding agent CLI adapters.

  Each adapter wraps a specific CLI tool (Claude Code, Aider, etc.) and
  tells `AgentProcess` how to invoke it and interpret its output.

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

  @doc "Returns CLI arguments to pass on startup for the given working directory."
  @callback args(dir :: String.t()) :: [String.t()]

  @doc "Returns additional environment variables as `{\"KEY\", \"VALUE\"}` tuples."
  @callback env(dir :: String.t()) :: [{String.t(), String.t()}]

  @doc """
  Inspects a chunk of stdout output and infers the agent's current status.

  Return one of `:idle | :running | :awaiting_input`, or `nil` to leave
  the status unchanged.
  """
  @callback parse_status(output :: binary()) :: :idle | :running | :awaiting_input | nil
end

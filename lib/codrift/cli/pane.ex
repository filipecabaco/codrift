defmodule Codrift.CLI.Pane do
  @moduledoc """
  CLI implementation for handing control back to the person at the keyboard.

  The same two operations the MCP server exposes as `open_terminal` and
  `focus_agent`, reachable from a plain shell. That matters because the MCP
  server is the part most likely to be missing: a CLI launched under a custom
  profile reads a different config directory and may never have been registered
  (see `codrift mcp install --profile`). An agent that can run `codrift` can
  still ask for a human without it.

  Unlike `codrift memory`, these need the desktop app running — a pane only
  exists inside a window, and the shell has to be a child of the app's
  supervision tree for the window to attach to it. Requests go to the local
  HTTP API via `Codrift.CLI.API`.

  All output is JSON to stdout; errors go to stderr with a non-zero exit.

  ## Usage

      codrift pane terminal <initiative_id> [--dir=<path>]
                                            [--command=<cmd>]
                                            [--reason=<text>]
      codrift pane focus    <agent_id> [--reason=<text>]

  `--command` is **typed at the prompt but not run**. The user reads it and
  presses Return themselves; that is the point, and it is what makes this safe
  to reach for on the steps an agent is not permitted to take.
  """

  import Codrift.CLI.API
  import Codrift.CLI.Output

  @doc "Dispatches pane CLI subcommands from argv."
  @spec run([String.t()]) :: :ok
  def run(["terminal", initiative_id | rest]) do
    case rpc("open_terminal", terminal_args(initiative_id, rest)) do
      {:ok, result} -> print_json(result)
      {:error, reason} -> fail(reason)
    end
  end

  def run(["focus", agent_id | rest]) do
    case rpc("focus_agent", focus_args(agent_id, rest)) do
      {:ok, result} -> print_json(result)
      {:error, reason} -> fail(reason)
    end
  end

  def run(_) do
    IO.puts("""
    Usage:
      codrift pane terminal <initiative_id> [--dir=<path>] [--command=<cmd>] [--reason=<text>]
      codrift pane focus    <agent_id> [--reason=<text>]

    Opens a shell in a Codrift pane and moves the user's keyboard into it, for
    a step only they can take: a commit you are not allowed to make, a
    credential prompt, a choice that is theirs.

      codrift pane terminal 91a2737 --dir=/Users/me/code/api \\
        --command='git commit -m "add refresh-token rotation"' \\
        --reason='review the staged auth changes and commit'

    --command is TYPED AT THE PROMPT BUT NOT RUN. Read the result back with
    `codrift initiative agents` and the app's own output view; do not assume it
    ran. The desktop app must be running.
    """)
  end

  # ── Argument parsing ─────────────────────────────────────────────────────────

  @doc false
  @spec terminal_args(String.t(), [String.t()]) :: map()
  def terminal_args(initiative_id, argv) do
    %{"initiative_id" => initiative_id}
    |> flag(argv, "dir")
    |> flag(argv, "command")
    |> flag(argv, "reason")
  end

  @doc false
  @spec focus_args(String.t(), [String.t()]) :: map()
  def focus_args(agent_id, argv), do: flag(%{"agent_id" => agent_id}, argv, "reason")
end

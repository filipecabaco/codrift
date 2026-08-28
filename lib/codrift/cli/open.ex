defmodule Codrift.CLI.Open do
  @moduledoc """
  CLI implementation of `open_file`: put a file in front of the user, and keep it.

  The shell-facing half of the MCP tool, for the same reason `codrift pane`
  exists — the MCP server is the part most likely to be missing. A CLI running
  under a custom profile reads a different config directory and may never have
  been registered (see `codrift mcp install --profile`), and an agent that can
  run `codrift` should still be able to say "this is the file".

  The file is linked into the initiative's context folder, so it stays one
  keypress away in the sidebar for the rest of the initiative. The link points
  at the real file, so later edits show through, and pinning the same file twice
  is a no-op.

  Needs the desktop app running: the pin lives in the app's own state and the
  open half is a window doing something. Requests go to the local HTTP API,
  authenticated with `~/.codrift/auth-token`.

  Output is JSON on stdout; errors go to stderr with a non-zero exit.

  ## Usage

      codrift open <initiative_id> <path> [--name=<name>] [--reason=<text>]
  """

  import Codrift.CLI.API
  import Codrift.CLI.Output

  @doc "Dispatches `codrift open` from argv."
  @spec run([String.t()]) :: :ok
  def run([initiative_id, path | rest]) when path != "" do
    case rpc("open_file", args(initiative_id, path, rest)) do
      {:ok, result} -> print_json(result)
      {:error, reason} -> fail(reason)
    end
  end

  def run(_) do
    IO.puts("""
    Usage:
      codrift open <initiative_id> <path> [--name=<name>] [--reason=<text>]

    Opens a file in a Codrift pane and links it into the initiative's context
    folder, so it stays in the sidebar for the rest of the initiative.

      codrift open 91a2737 lib/codrift/agent/process.ex \\
        --reason='the PTY write path the bug is on'

    Use it for the file the work actually turns on, not for every file you read.
    The path must be inside one of the initiative's directories; add it first
    with `codrift initiative add-dir` if it is not. Pinning the same file twice
    changes nothing. The desktop app must be running.
    """)
  end

  # ── Argument parsing ─────────────────────────────────────────────────────────

  @doc false
  @spec args(String.t(), String.t(), [String.t()]) :: map()
  def args(initiative_id, path, argv) do
    # Expanded here rather than on the server: a relative path means "relative
    # to the shell I typed this in", and the app's cwd is not that shell's.
    %{"initiative_id" => initiative_id, "path" => Path.expand(path)}
    |> flag(argv, "name")
    |> flag(argv, "reason")
  end
end

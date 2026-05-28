defmodule Codrift.CLI.MCP do
  @moduledoc """
  CLI implementation for MCP server registration.

  The Mix task (`mix codrift.mcp.install`) delegates to this module, and the
  release command (`codrift mcp install`) calls it via `eval`.  There is a
  single source of logic in one place.

  ## Usage

      codrift mcp install
      codrift mcp install --port=7437

  Attempts to run `claude mcp add` to register the Codrift SSE endpoint.
  Falls back to printing the manual install command when the Claude CLI is not
  found or the command fails.
  """

  @server_name "codrift"
  @default_port 7_437

  @doc "Dispatches MCP CLI subcommands from argv."
  @spec run([String.t()]) :: :ok
  def run(["install" | args]), do: install(args)

  def run(_) do
    IO.puts("""
    Usage:
      codrift mcp install [--port=<port>]

    Registers the Codrift MCP server with Claude Code (or prints the manual
    install command if the Claude CLI is not found).
    """)
  end

  # ── Subcommands ──────────────────────────────────────────────────────────────

  defp install(args) do
    port = parse_port(args)
    sse_url = "http://localhost:#{port}/mcp/sse"
    install_cmd = "claude mcp add #{@server_name} --transport sse #{sse_url}"

    case System.find_executable("claude") do
      nil ->
        IO.puts("""
        Claude CLI not found in PATH. Add the MCP server manually:

            #{install_cmd}

        Or for other MCP clients, point them at the SSE endpoint:

            #{sse_url}
        """)

      _claude ->
        IO.puts("Registering Codrift MCP server with Claude Code...")

        case System.cmd("claude", ["mcp", "add", @server_name, "--transport", "sse", sse_url],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            IO.puts("Done. #{String.trim(output)}")
            IO.puts("\nVerify with: claude mcp list")

          {output, code} ->
            IO.puts(:stderr, "claude mcp add exited #{code}: #{String.trim(output)}")
            IO.puts("\nManual install:\n\n    #{install_cmd}\n")
        end
    end
  end

  defp parse_port(args) do
    case Enum.find(args, &String.starts_with?(&1, "--port=")) do
      nil -> @default_port
      flag -> flag |> String.slice(7..-1//1) |> String.to_integer()
    end
  end
end

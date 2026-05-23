defmodule Mix.Tasks.Codrift.Mcp.Install do
  @moduledoc """
  Registers the Codrift MCP server with an MCP client.

  ## Usage

      mix codrift.mcp.install

  Attempts to run `claude mcp add` to register the server. Falls back to
  printing the manual install command if the Claude CLI is not found.

  The server must be running on port 7437 (or the configured port) before
  MCP clients can connect.
  """

  use Mix.Task

  @shortdoc "Register Codrift MCP server with Claude Code (or print install command)"

  @server_name "codrift"
  @default_port 7437

  @impl Mix.Task
  def run(_args) do
    port = Application.get_env(:codrift, :bandit_opts, []) |> Keyword.get(:port, @default_port)
    sse_url = "http://localhost:#{port}/mcp/sse"
    install_cmd = "claude mcp add #{@server_name} --transport sse #{sse_url}"

    case System.find_executable("claude") do
      nil ->
        Mix.shell().info("""
        Claude CLI not found in PATH. Add the MCP server manually:

            #{install_cmd}

        Or for other MCP clients, point them at the SSE endpoint:

            #{sse_url}
        """)

      claude ->
        Mix.shell().info("Registering Codrift MCP server with Claude Code...")

        case System.cmd(claude, ["mcp", "add", @server_name, "--transport", "sse", sse_url],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            Mix.shell().info("Done. #{String.trim(output)}")
            Mix.shell().info("\nVerify with: claude mcp list")

          {output, code} ->
            Mix.shell().error("claude mcp add exited #{code}: #{String.trim(output)}")
            Mix.shell().info("\nManual install:\n\n    #{install_cmd}\n")
        end
    end
  end
end

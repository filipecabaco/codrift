defmodule Mix.Tasks.Codrift.Mcp.Install do
  @moduledoc """
  Registers the Codrift MCP server with an MCP client.

  ## Usage

      mix codrift.mcp.install

  Attempts to run `claude mcp add` to register the server. Falls back to
  printing the manual install command if the Claude CLI is not found.

  The server must be running on port 43117 (or the configured port) before
  MCP clients can connect.
  """

  use Mix.Task

  alias Codrift.CLI.MCP

  @shortdoc "Register Codrift MCP server with Claude Code (or print install command)"

  @impl Mix.Task
  def run(args), do: MCP.run(["install" | args])
end

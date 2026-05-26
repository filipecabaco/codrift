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

  alias Codrift.CLI.MCP

  @shortdoc "Register Codrift MCP server with Claude Code (or print install command)"

  @impl Mix.Task
  def run(args) do
    # In the Mix context the application config is available, so honour any
    # custom port set via `config :codrift, bandit_opts: [port: N]` — unless
    # the caller already supplied an explicit --port=N flag.
    has_port_flag = Enum.any?(args, &String.starts_with?(&1, "--port="))

    port_flag =
      if has_port_flag do
        []
      else
        port = Application.get_env(:codrift, :bandit_opts, []) |> Keyword.get(:port, 7437)
        ["--port=#{port}"]
      end

    MCP.run(["install"] ++ port_flag ++ args)
  end
end

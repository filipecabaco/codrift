defmodule Mix.Tasks.Codrift.Tui do
  @moduledoc """
  Starts the Codrift terminal UI.

  Boots the full application (web server on port 7437, agent supervisor,
  initiative store) then opens the TUI on the current terminal. Press
  `q` or `Ctrl+C` to quit.

  ## Usage

      mix codrift.tui
      mix codrift.tui file1.ex lib/foo/bar.ex

  Pass one or more file or directory paths to open them as a temporary
  initiative directly in the TUI.

  The web server keeps running in the background while the TUI is open,
  so `http://localhost:7437/diff.html` and `POST /mcp` remain accessible.
  """

  use Mix.Task

  @shortdoc "Start the Codrift TUI"

  @impl Mix.Task
  alias Codrift.CLI.TUI

  def run(args), do: TUI.run(args)
end

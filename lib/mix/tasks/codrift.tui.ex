defmodule Mix.Tasks.Codrift.Tui do
  @moduledoc """
  Starts the Codrift terminal UI.

  Boots the full application (web server on port 7437, agent supervisor,
  initiative store) then opens the TUI on the current terminal. Press
  `q` or `Ctrl+C` to quit.

  ## Usage

      mix codrift.tui

  The web server keeps running in the background while the TUI is open,
  so `http://localhost:7437/diff.html` and `POST /mcp` remain accessible.
  """

  use Mix.Task

  @shortdoc "Start the Codrift TUI"

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:codrift)

    # Suppress console logging so the TUI owns the terminal cleanly.
    Logger.configure(level: :none)

    {:ok, pid} = Codrift.TUI.start_link([])
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end
end

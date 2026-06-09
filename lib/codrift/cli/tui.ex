defmodule Codrift.CLI.TUI do
  @moduledoc """
  CLI entry point for the Codrift TUI, used from the release binary.

  The Mix task (`mix codrift.tui`) delegates to this module so there is a
  single source of truth for TUI startup.

  In release context this is invoked via `rel/commands/tui.sh`, which calls
  `eval 'Codrift.CLI.TUI.run(System.argv())'`.  Unlike other CLI modules that
  run without a supervision tree, TUI startup requires the full application —
  `run/1` calls `Application.ensure_all_started(:codrift)` explicitly before
  opening the terminal interface.
  """

  @doc "Starts the full application and opens the TUI. Blocks until the TUI exits."
  @spec run([String.t()]) :: :ok
  def run([]) do
    start_tui([])
  end

  def run(paths) do
    initiative = Codrift.Initiative.create_temp(paths)
    start_tui(temp_initiative: initiative)
  end

  defp start_tui(opts) do
    {:ok, _} = Application.ensure_all_started(:codrift)

    Logger.configure(level: :error)

    {:ok, pid} = Codrift.TUI.start_link(opts)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end
end

defmodule Codrift.CLI.Update do
  @moduledoc "Self-update command: checks for a newer release and installs it."

  alias Codrift.Updater

  @spec run([String.t()]) :: :ok
  def run(["--check"]) do
    Application.ensure_all_started(:req)

    case Updater.check() do
      {:update_available, _current, latest} ->
        IO.puts(latest)
        System.halt(0)

      _ ->
        System.halt(1)
    end
  end

  def run([]) do
    Application.ensure_all_started(:req)
    current = Updater.current_version()
    IO.puts("Current version: #{current}")
    IO.write("Checking for updates... ")

    case Updater.check() do
      {:up_to_date, version} ->
        IO.puts("already up to date (#{version}).")

      {:update_available, _current, latest} ->
        IO.puts("new version available: #{latest}")
        IO.write("Downloading and installing... ")

        case Updater.install(latest) do
          :ok ->
            IO.puts("done.")
            IO.puts("Restart codrift to use version #{latest}.")

          {:error, reason} ->
            IO.puts("failed.")
            IO.puts(:stderr, "Error: #{reason}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts("failed.")
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  def run(_) do
    IO.puts("""
    Usage:
      codrift update           Check for a newer release and install it
      codrift update --check   Exit 0 if an update is available, 1 if not
    """)
  end
end

defmodule Codrift.CLI.Start do
  @moduledoc """
  Launches the Codrift desktop app.

  The CLI and the app are installed as two separate artifacts (the Homebrew
  cask/DMG carries `Codrift.app`, the formula/tarball carries this binary), so
  `codrift start` is the one command that bridges them — you get the desktop
  surface without leaving the shell or hunting through /Applications.
  """

  # Where install.sh drops the Linux AppImage, plus the paths a .deb uses.
  @linux_candidates [
    "~/.local/bin/codrift-app",
    "/usr/bin/codrift-app",
    "/usr/local/bin/codrift-app",
    "/opt/Codrift/codrift"
  ]

  @spec run([String.t()]) :: :ok
  def run([]) do
    case launch() do
      :ok ->
        IO.puts("Starting Codrift.")

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  def run(_) do
    IO.puts("""
    Usage:
      codrift start   Launch the Codrift desktop app
    """)
  end

  defp launch do
    case :os.type() do
      {:unix, :darwin} -> launch_macos()
      {:unix, _} -> launch_linux()
      other -> {:error, "unsupported platform: #{inspect(other)}"}
    end
  end

  # `open -a` goes through LaunchServices, so it finds the app in /Applications
  # or ~/Applications, and focuses an already-running instance instead of
  # starting a second one (which could never bind the port anyway).
  defp launch_macos do
    case System.cmd("open", ["-a", "Codrift"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, "could not launch Codrift.app — #{String.trim(out)}\n#{hint()}"}
    end
  end

  defp launch_linux do
    candidates = Enum.map(@linux_candidates, &Path.expand/1)

    case Enum.find(candidates, &File.regular?/1) || System.find_executable("codrift-app") do
      nil ->
        {:error, "could not find the Codrift app binary.\n#{hint()}"}

      path ->
        # Detach deliberately: a bare spawn is a child of this short-lived CLI
        # process, so the window would close the moment the command returned.
        case System.cmd("sh", ["-c", "nohup \"$1\" >/dev/null 2>&1 &", "sh", path]) do
          {_, 0} -> :ok
          {out, _} -> {:error, "could not launch #{path} — #{String.trim(out)}"}
        end
    end
  end

  defp hint, do: "Install it with: brew install --cask codrift"
end

defmodule Codrift.Paths do
  @moduledoc "Shared path utilities used across TUI, sidebar, and stores."

  @doc """
  Replaces the user's home directory prefix with `~`.

  Returns the path unchanged when it does not live under the home directory.

      iex> Codrift.Paths.compact(Path.expand("~/foo/bar"))
      "~/foo/bar"
  """
  def compact(path) do
    home = Path.expand("~")
    relative = Path.relative_to(path, home)
    if relative == path, do: path, else: "~/#{relative}"
  end
end

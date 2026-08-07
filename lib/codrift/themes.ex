defmodule Codrift.Themes do
  @moduledoc """
  User-supplied VS Code colour themes, read from `~/.codrift/themes/*.json`.

  Codrift ships the themes Shiki bundles, but the point of speaking VS Code's
  theme format is that the rest of the ecosystem is available too: drop a
  theme's JSON (the file a VS Code theme extension keeps in `themes/`) into
  that folder and it shows up in the picker.

  Only the file *name* crosses the API — never a path — so a request can't
  reach outside the folder.
  """

  @doc "Directory holding user themes. Created on demand by `write/2` in tests."
  def dir, do: Path.join(Codrift.Paths.data_dir(), "themes")

  @doc """
  Lists available theme file names (e.g. `["night-owl.json"]`), sorted.

  A missing folder is not an error — most users never add one.
  """
  @spec list() :: [String.t()]
  def list do
    case File.ls(dir()) do
      {:ok, names} -> names |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()
      {:error, _} -> []
    end
  end

  @doc """
  Reads and decodes one theme by file name.

  Returns `{:error, :not_found}` for an unknown or non-`.json` name, and
  `{:error, :invalid}` when the file is not a JSON object with a `colors` map —
  the one thing the UI needs to skin itself.
  """
  @spec read(String.t()) :: {:ok, map()} | {:error, :not_found | :invalid}
  def read(name) when is_binary(name) do
    with :ok <- validate_name(name),
         path = Path.join(dir(), name),
         {:ok, content} <- File.read(path),
         {:ok, %{"colors" => colors} = theme} when is_map(colors) <- JSON.decode(content) do
      {:ok, theme}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, :invalid_name} -> {:error, :not_found}
      {:ok, _not_a_theme} -> {:error, :invalid}
      # JSON.decode/1 reports failures as `{:error, {:invalid_byte, ...}}` and
      # friends — it never returns a %JSON.DecodeError{} (only decode!/1 raises
      # one), so this clause catches every decode failure.
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp validate_name(name) do
    if name == Path.basename(name) and String.ends_with?(name, ".json") and
         name not in ["", ".", ".."],
       do: :ok,
       else: {:error, :invalid_name}
  end
end

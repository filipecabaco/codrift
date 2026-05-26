defmodule Codrift.Config.Theme do
  @moduledoc """
  Theme configuration for the Codrift TUI.

  The active theme is loaded from `~/.codrift/theme.json`. If the file does not
  exist, the `:default` theme is used.

  ## Example `~/.codrift/theme.json`

      {"theme": "dracula"}

  ## Available themes

  | Name | Description |
  |------|-------------|
  | `default` | Yellow focused border, dark-gray unfocused (original Codrift colours) |
  | `dracula` | Purple accents, green diff border |
  | `nord` | Arctic blue accents, teal diff border |
  | `solarized` | Warm amber accents, teal diff border |
  | `tokyo_night` | Deep blue accents, pink diff border |

  ## Theme fields

  Each theme defines:
  - `border_focused` — colour of the focused pane border
  - `border_unfocused` — colour of unfocused pane borders
  - `diff_border` — colour of the diff content pane border (always "active")
  - `sidebar_highlight` — background colour for the selected sidebar row
  - `syntax_theme` — atom passed to `CodeBlock :theme` for syntax highlighting
  """

  defstruct [
    :name,
    :border_focused,
    :border_unfocused,
    :diff_border,
    :sidebar_highlight,
    :syntax_theme
  ]

  @type t :: %__MODULE__{
          name: atom(),
          border_focused: term(),
          border_unfocused: term(),
          diff_border: term(),
          sidebar_highlight: term(),
          syntax_theme: atom()
        }

  # ── Built-in themes ──────────────────────────────────────────────────────────

  @doc "Returns the built-in default theme (`:default`)."
  @spec default() :: t()
  def default, do: themes().default

  @doc "Returns a map of all built-in themes keyed by atom name."
  @spec all() :: %{atom() => t()}
  def all, do: themes()

  @doc """
  Returns the theme struct for the given name atom, or the default theme if the
  name is not recognised.
  """
  @spec get(atom()) :: t()
  def get(name), do: Map.get(themes(), name, themes().default)

  defp themes do
    %{
      default: %__MODULE__{
        name: :default,
        border_focused: :yellow,
        border_unfocused: {:indexed, 238},
        diff_border: :cyan,
        sidebar_highlight: :cyan,
        syntax_theme: :base16_ocean_dark
      },
      dracula: %__MODULE__{
        name: :dracula,
        # purple
        border_focused: {:indexed, 141},
        border_unfocused: {:indexed, 238},
        # green
        diff_border: {:indexed, 84},
        sidebar_highlight: {:indexed, 141},
        syntax_theme: :base16_ocean_dark
      },
      nord: %__MODULE__{
        name: :nord,
        # frost blue
        border_focused: {:indexed, 67},
        border_unfocused: {:indexed, 238},
        # teal
        diff_border: {:indexed, 73},
        sidebar_highlight: {:indexed, 67},
        syntax_theme: :base16_ocean_dark
      },
      solarized: %__MODULE__{
        name: :solarized,
        # amber
        border_focused: {:indexed, 136},
        border_unfocused: {:indexed, 240},
        # teal
        diff_border: {:indexed, 37},
        sidebar_highlight: {:indexed, 136},
        syntax_theme: :base16_ocean_dark
      },
      tokyo_night: %__MODULE__{
        name: :tokyo_night,
        # blue accent
        border_focused: {:indexed, 111},
        border_unfocused: {:indexed, 237},
        # pink/red
        diff_border: {:indexed, 203},
        sidebar_highlight: {:indexed, 111},
        syntax_theme: :base16_ocean_dark
      }
    }
  end

  @doc """
  Loads the theme from `~/.codrift/theme.json`.

  The file must contain a JSON object with a `"theme"` string key matching one of
  the built-in theme names. Unrecognised names and parse errors fall back to the
  default theme.

  ## Example

      {"theme": "dracula"}
  """
  @spec load() :: t()
  def load do
    path = Path.join(Path.expand("~/.codrift"), "theme.json")

    name =
      with {:ok, raw} <- File.read(path),
           {:ok, %{"theme" => theme_str}} <- JSON.decode(raw),
           atom when is_atom(atom) <- parse_name(theme_str) do
        atom
      else
        _ -> :default
      end

    get(name)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp parse_name("default"), do: :default
  defp parse_name("dracula"), do: :dracula
  defp parse_name("nord"), do: :nord
  defp parse_name("solarized"), do: :solarized
  defp parse_name("tokyo_night"), do: :tokyo_night
  defp parse_name(_), do: nil
end

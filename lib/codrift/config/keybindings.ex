defmodule Codrift.Config.Keybindings do
  @moduledoc """
  Keybinding configuration for the Codrift TUI.

  Custom keybindings are loaded from `~/.codrift/keybindings.json`.
  Any action omitted from the file falls back to its default.

  ## Example `~/.codrift/keybindings.json`

      {
        "navigate_down": "j",
        "navigate_up": "k",
        "quit": "x",
        "toggle_sidebar": "ctrl+h"
      }

  ## Supported actions

  | Action | Default | Description |
  |--------|---------|-------------|
  | `navigate_down` | `j` | Move sidebar cursor down |
  | `navigate_up` | `k` | Move sidebar cursor up |
  | `new_initiative` | `n` | Create a new initiative |
  | `add_dir` | `a` | Add a directory to the current initiative |
  | `start_agent` | `s` | Start a Claude agent |
  | `start_terminal` | `t` | Open a terminal in the current directory |
  | `delete` | `d` | Delete or stop the current item |
  | `edit_context` | `e` | Open context file editor |
  | `new_context` | `c` | Create a new context file |
  | `refresh` | `r` | Refresh the current pane |
  | `status_prev` | `[` | Cycle initiative status backward |
  | `status_next` | `]` | Cycle initiative status forward |
  | `context_mode` | `1` | Switch to context view |
  | `diff_mode` | `2` | Switch to diff view |
  | `toggle_diff_view` | `v` | Toggle unified/split diff |
  | `diff_all_files` | `*` | Show all changed files |
  | `quit` | `q` | Quit Codrift |
  | `toggle_sidebar` | `ctrl+b` | Collapse/expand sidebar |
  | `palette` | `ctrl+p` | Open command palette |

  ## Key spec format

  - Single character: `"j"`, `"q"`, `"["`, `"*"`
  - Modifier combo: `"ctrl+b"`, `"ctrl+p"`, `"alt+x"`, `"shift+r"`
  """

  @default_bindings %{
    navigate_down: "j",
    navigate_up: "k",
    new_initiative: "n",
    add_dir: "a",
    start_agent: "s",
    start_terminal: "t",
    delete: "d",
    edit_context: "e",
    new_context: "c",
    refresh: "r",
    status_prev: "[",
    status_next: "]",
    context_mode: "1",
    diff_mode: "2",
    toggle_diff_view: "v",
    diff_all_files: "*",
    quit: "q",
    toggle_sidebar: "ctrl+b",
    palette: "ctrl+p"
  }

  @type action ::
          :navigate_down
          | :navigate_up
          | :new_initiative
          | :add_dir
          | :start_agent
          | :start_terminal
          | :delete
          | :edit_context
          | :new_context
          | :refresh
          | :status_prev
          | :status_next
          | :context_mode
          | :diff_mode
          | :toggle_diff_view
          | :diff_all_files
          | :quit
          | :toggle_sidebar
          | :palette

  @type key_spec :: String.t()
  @type t :: %{required(action()) => key_spec()}

  @doc "Returns the built-in default keybindings map."
  @spec defaults() :: t()
  def defaults, do: @default_bindings

  @doc """
  Loads keybindings from `~/.codrift/keybindings.json`, merging user overrides
  over the defaults.

  Unknown action names in the file are silently ignored. If the file does not
  exist or cannot be parsed, the defaults are returned unchanged.
  """
  @spec load() :: t()
  def load do
    path = Path.join(Path.expand("~/.codrift"), "keybindings.json")

    overrides =
      with {:ok, raw} <- File.read(path),
           {:ok, parsed} <- JSON.decode(raw) do
        parsed
        |> Enum.flat_map(fn {k, v} ->
          with action when not is_nil(action) <- string_to_action(k),
               true <- is_binary(v) do
            [{action, v}]
          else
            _ -> []
          end
        end)
        |> Map.new()
      else
        _ -> %{}
      end

    Map.merge(@default_bindings, overrides)
  end

  @doc """
  Builds a reverse lookup map: `key_spec → action atom`.

  Used for O(1) key dispatch in the TUI event loop.
  Collisions (two actions sharing the same key) keep only the last one.
  """
  @spec build_reverse(t()) :: %{required(key_spec()) => action()}
  def build_reverse(bindings) do
    Map.new(bindings, fn {action, key} -> {key, action} end)
  end

  @doc "Returns the configured key spec for an action, or `nil` if not found."
  @spec key_for(t(), action()) :: key_spec() | nil
  def key_for(bindings, action), do: Map.get(bindings, action)

  @doc """
  Parses a key spec string into `{code, modifiers}` compatible with
  `ExRatatui.Event.Key`.

      iex> Codrift.Config.Keybindings.parse_spec("ctrl+b")
      {"b", ["ctrl"]}

      iex> Codrift.Config.Keybindings.parse_spec("j")
      {"j", []}
  """
  @spec parse_spec(key_spec()) :: {String.t(), [String.t()]}
  def parse_spec(spec) do
    case String.split(spec, "+", parts: 2) do
      [mod, key] when mod in ["ctrl", "alt", "shift"] -> {key, [mod]}
      _ -> {spec, []}
    end
  end

  @doc """
  Formats a key spec for display in hints and the status bar.

      iex> Codrift.Config.Keybindings.format("ctrl+p")
      "Ctrl+P"

      iex> Codrift.Config.Keybindings.format("j")
      "j"
  """
  @spec format(key_spec()) :: String.t()
  def format("ctrl+" <> key), do: "Ctrl+#{String.upcase(key)}"
  def format("alt+" <> key), do: "Alt+#{String.upcase(key)}"
  def format("shift+" <> key), do: "Shift+#{String.upcase(key)}"
  def format(key), do: key

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp string_to_action("navigate_down"), do: :navigate_down
  defp string_to_action("navigate_up"), do: :navigate_up
  defp string_to_action("new_initiative"), do: :new_initiative
  defp string_to_action("add_dir"), do: :add_dir
  defp string_to_action("start_agent"), do: :start_agent
  defp string_to_action("start_terminal"), do: :start_terminal
  defp string_to_action("delete"), do: :delete
  defp string_to_action("edit_context"), do: :edit_context
  defp string_to_action("new_context"), do: :new_context
  defp string_to_action("refresh"), do: :refresh
  defp string_to_action("status_prev"), do: :status_prev
  defp string_to_action("status_next"), do: :status_next
  defp string_to_action("context_mode"), do: :context_mode
  defp string_to_action("diff_mode"), do: :diff_mode
  defp string_to_action("toggle_diff_view"), do: :toggle_diff_view
  defp string_to_action("diff_all_files"), do: :diff_all_files
  defp string_to_action("quit"), do: :quit
  defp string_to_action("toggle_sidebar"), do: :toggle_sidebar
  defp string_to_action("palette"), do: :palette
  defp string_to_action(_), do: nil
end

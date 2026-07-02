defmodule Codrift.Config.Keybindings do
  @moduledoc """
  Keybinding configuration for Codrift.

  The desktop app fetches these over the `get_keybindings` RPC and drives its
  own key dispatch (see `assets/src/lib/keys.ts`).

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
  | `tree_mode` | `3` | Switch to tree view |
  | `toggle_diff_view` | `v` | Toggle unified/split diff |
  | `diff_all_files` | `*` | Show all changed files |
  | `quit` | `ctrl+q` | Quit Codrift |
  | `toggle_sidebar` | `ctrl+b` | Collapse/expand sidebar |
  | `palette` | `ctrl+p` | Open command palette |
  | `start_orchestration` | `o` | Start orchestration for the selected initiative |

  ## Key spec format

  - Single character: `"j"`, `"["`, `"*"`
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
    tree_mode: "3",
    toggle_diff_view: "v",
    diff_all_files: "*",
    quit: "ctrl+q",
    toggle_sidebar: "ctrl+b",
    palette: "ctrl+p",
    start_orchestration: "o"
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
          | :tree_mode
          | :toggle_diff_view
          | :diff_all_files
          | :quit
          | :toggle_sidebar
          | :palette
          | :start_orchestration

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
    path = Path.join(Codrift.Paths.data_dir(), "keybindings.json")

    overrides =
      with {:ok, raw} <- File.read(path),
           {:ok, parsed} <- JSON.decode(raw) do
        parsed
        |> Enum.flat_map(&parse_binding/1)
        |> Map.new()
      else
        _ -> %{}
      end

    Map.merge(@default_bindings, overrides)
  end

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
  defp string_to_action("tree_mode"), do: :tree_mode
  defp string_to_action("toggle_diff_view"), do: :toggle_diff_view
  defp string_to_action("diff_all_files"), do: :diff_all_files
  defp string_to_action("quit"), do: :quit
  defp string_to_action("toggle_sidebar"), do: :toggle_sidebar
  defp string_to_action("palette"), do: :palette
  defp string_to_action("start_orchestration"), do: :start_orchestration
  defp string_to_action(_), do: nil

  defp parse_binding({k, v}) do
    with action when not is_nil(action) <- string_to_action(k),
         true <- is_binary(v) do
      [{action, v}]
    else
      _ -> []
    end
  end
end

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
  | `new_scratchpad` | `ctrl+n` | Open a scratchpad — an unnamed initiative for quick exploration |
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
  | `branch_initiative` | `b` | Put every git directory on the initiative's branch |
  | `initiative_agent` | `p` | Pick which agent/profile the selected initiative launches |
  | `settings` | `ctrl+,` | Open Settings |
  | `focus_left` | `ctrl+left` | Move focus left: pane → pane → sidebar |
  | `focus_right` | `ctrl+right` | Move focus right: sidebar → pane → pane |
  | `focus_up` | `ctrl+up` | Move focus up, between stacked panes |
  | `focus_down` | `ctrl+down` | Move focus down, between stacked panes |

  The desktop app also owns a few positional window-management combos, which are
  not actions and so are not rebindable here: the primary modifier with a digit
  (`⌘1`, `⌘2`, …) jumps straight to a pane, `⌘D` / `⌘⇧D` splits the focused pane
  right / down, `⌘⌃=` balances every pane, and `⌘W` closes the focused one.
  `⌘K` clears the focused terminal — macOS only, because `⌃K` is
  kill-to-end-of-line in every readline and the terminal keeps it elsewhere.

  ## Key spec format

  - Single character: `"j"`, `"["`, `"*"`
  - Named key: `"left"`, `"right"`, `"up"`, `"down"`, `"esc"`
  - Modifier combo: `"ctrl+b"`, `"ctrl+p"`, `"ctrl+left"`, `"alt+x"`, `"shift+r"`

  ## Bindings that must not be reachable without a modifier

  The `focus_*` actions are the only way out of a focused terminal, because the
  pane keeps `Tab` for the PTY (shell completion and an agent's own mode cycling
  both need it). Bind them to *modifier* combos. A bare key would be typed
  straight into the agent, and their predecessor — `ctrl+esc` — was worse still:
  releasing the modifier a moment early sent a lone `Esc`, which coding CLIs read
  as "interrupt the running command".
  """

  @default_bindings %{
    navigate_down: "j",
    navigate_up: "k",
    new_initiative: "n",
    new_scratchpad: "ctrl+n",
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
    start_orchestration: "o",
    branch_initiative: "b",
    initiative_agent: "p",
    settings: "ctrl+,",
    # Git, as a row of bare keys: bare because the capture handler eats modifier
    # combos before the PTY sees them, and taking ⌃R from a shell to mean
    # "rebase" would cost every user reverse-search. f/m/u are mnemonic; g is
    # simply the free key that keeps the four together.
    git_fetch: "f",
    git_rebase: "g",
    git_commit: "m",
    git_push: "u",
    focus_left: "ctrl+left",
    focus_right: "ctrl+right",
    focus_up: "ctrl+up",
    focus_down: "ctrl+down"
  }

  @type action ::
          :navigate_down
          | :navigate_up
          | :new_initiative
          | :new_scratchpad
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
          | :branch_initiative
          | :initiative_agent
          | :git_fetch
          | :git_rebase
          | :git_commit
          | :git_push
          | :settings
          | :focus_left
          | :focus_right
          | :focus_up
          | :focus_down

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
  defp string_to_action("new_scratchpad"), do: :new_scratchpad
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
  defp string_to_action("branch_initiative"), do: :branch_initiative
  defp string_to_action("initiative_agent"), do: :initiative_agent
  defp string_to_action("settings"), do: :settings
  defp string_to_action("git_fetch"), do: :git_fetch
  defp string_to_action("git_rebase"), do: :git_rebase
  defp string_to_action("git_commit"), do: :git_commit
  defp string_to_action("git_push"), do: :git_push
  defp string_to_action("focus_left"), do: :focus_left
  defp string_to_action("focus_right"), do: :focus_right
  defp string_to_action("focus_up"), do: :focus_up
  defp string_to_action("focus_down"), do: :focus_down
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

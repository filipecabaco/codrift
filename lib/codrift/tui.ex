defmodule Codrift.TUI do
  @moduledoc """
  Terminal UI for Codrift, built on `ExRatatui.App`.

  ## Layout

      ┌──────────────────────────────────────────────┐
      │ ● Context  ○ 2: Diff                         │  mode indicator
      ├─────────────┬────────────────────────────────┤
      │ Initiatives │                                │
      │  └ ▸ dir    │  Context-driven main pane      │
      │     └ agent │  (updates as cursor moves)     │
      ├─────────────┴────────────────────────────────┤
      │ status / hints                               │  footer
      └──────────────────────────────────────────────┘

  ## Context-driven main pane

  The main pane reflects whatever the sidebar cursor is pointing at:

  - **Initiative** — initiative overview: directories, branches, agent counts
  - **Directory** — folder info: git branch, remote, last 5 commits
  - **Agent** — agent output (auto-subscribes; no Enter needed)

  Press `2` to switch to an explicit diff view of the selected initiative.
  Press `1` to return to context mode.

  ## Keybindings

  All keys below are the **defaults**. Override any of them by creating
  `~/.codrift/keybindings.json` — see `Codrift.Config.Keybindings` for details.

  | Key | Action |
  |-----|--------|
  | `j` / `↓` | Move down / scroll main pane |
  | `k` / `↑` | Move up / scroll main pane |
  | `Tab` | Cycle focus sidebar→main; insert `\t` in input (main pane) |
  | `Shift+Tab` | Cycle focus main→sidebar |
  | `Esc` | Clear input buffer (non-PTY); forward `\e` to PTY |
  | `Shift+Enter` | Insert newline in input buffer (non-PTY) |
  | `Ctrl+V` | Toggle paste mode — Enter inserts `\n` instead of submitting |
  | `n` | New initiative |
  | `a` | Add directory (context-sensitive) |
  | `s` | Start Claude agent (context-sensitive) |
  | `d` | Delete / remove / stop (context-sensitive with confirmation) |
  | `Ctrl+P` | Command palette |
  | `Ctrl+B` | Toggle sidebar (collapse / expand) |
  | `1` | Context mode (default) |
  | `2` | Diff mode for selected initiative |
  | `v` | Toggle diff view: unified ↔ split (diff mode only) |
  | `*` | Reset diff sidebar to "all files" (diff mode only) |
  | `r` | Refresh current pane |
  | `Ctrl+D` / `Ctrl+U` | Scroll half-page |
  | `Ctrl+Q` / `Ctrl+C` | Quit (kills all running agents) |

  ## Themes

  Set the visual theme by creating `~/.codrift/theme.json`:

      {"theme": "dracula"}

  Available themes: `default`, `dracula`, `nord`, `solarized`, `tokyo_night`.
  See `Codrift.Config.Theme` for full details.
  """

  use ExRatatui.App

  alias ExRatatui.Event.{Key, Mouse, Paste}
  alias ExRatatui.{Focus, Layout, Style}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.CodeBlock
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Textarea

  alias Codrift.Agent.Adapters.{Aider, Claude, Terminal}
  alias Codrift.{AgentProcess, AgentSupervisor, Diff, Initiative, Paths}
  alias Codrift.Config.{Keybindings, Theme}
  alias Codrift.Initiative.{DirEntry, Store}
  alias Codrift.OAuth.Config, as: OAuthConfig
  alias Codrift.Worktree

  alias Codrift.TUI.{
    AgentState,
    DirPicker,
    EditorState,
    Modals,
    ModalState,
    Selection,
    Sidebar,
    SidebarState,
    Styles,
    VT100
  }

  @type modal :: :none | :new_name | :new_dir | :confirm_delete | :palette | :theme_picker
  @type tab :: :context | :diff

  defstruct [
    :focus,
    :pane_size,
    :term_size,
    :active_tab,
    :cursor_info,
    :main_scroll,
    :status,
    :input_buffer,
    :theme,
    paste_mode: false,
    kb: %{bindings: %{}, reverse: %{}},
    sidebar: %SidebarState{},
    selection: %Selection{},
    agents: %AgentState{},
    editor: %EditorState{},
    modal: %ModalState{},
    diff: %{files: [], scroll: 0, view_mode: :unified, sidebar_entries: [], sidebar_cursor: 0},
    refs: %{resize: nil, sidebar_tick: nil, status_timer: nil, nudge: nil, restore: nil}
  ]

  @impl true
  def mount(_opts) do
    Process.send_after(self(), :autostart_sessions, 300)
    Codrift.Updater.check_async(self())
    initiatives = Store.list()
    agents = Enum.map(AgentSupervisor.list_agents(), &AgentProcess.status/1)

    {term_w, term_h} = ExRatatui.terminal_size()
    {pane_cols, pane_rows} = calc_pane_size(term_w, term_h)

    keybindings = Keybindings.load()
    keybindings_reverse = Keybindings.build_reverse(keybindings)
    theme = Theme.load()

    initial_state = %__MODULE__{
      focus: Focus.new([:sidebar, :main]),
      pane_size: {pane_cols, pane_rows},
      term_size: {term_w, term_h},
      active_tab: :context,
      cursor_info: nil,
      main_scroll: 0,
      status: build_default_status(keybindings),
      input_buffer: "",
      theme: theme,
      kb: %{bindings: keybindings, reverse: keybindings_reverse},
      sidebar: %SidebarState{
        entries: Sidebar.build_entries(initiatives, agents),
        cursor: 0,
        collapsed: false
      },
      selection: %Selection{},
      agents: %AgentState{
        subscribed: MapSet.new(),
        outputs: %{},
        screens: %{}
      },
      editor: %EditorState{
        file: nil,
        ref: ExRatatui.textarea_new(),
        autosave: nil
      },
      modal: %ModalState{
        type: :none,
        input: ExRatatui.text_input_new(),
        context: nil,
        actions: build_actions(keybindings),
        palette: %{cursor: 0, filter: ""},
        theme_picker: %{cursor: 0, before: nil},
        dir_picker: %{suggestions: [], cursor: 0}
      },
      diff: %{files: [], scroll: 0, view_mode: :unified, sidebar_entries: [], sidebar_cursor: 0},
      refs: %{
        resize: nil,
        sidebar_tick: Process.send_after(self(), :sidebar_tick, 2000),
        status_timer: nil,
        nudge: nil,
        restore: nil
      }
    }

    {:ok, update_context_from_cursor(initial_state)}
  end

  @impl true
  def render(state, frame) do
    full = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [header_rect, body_rect, footer_rect] =
      Layout.split(full, :vertical, [{:length, 1}, {:min, 0}, {:length, 1}])

    {sidebar_widgets, main_rect} =
      if state.sidebar.collapsed do
        {[], body_rect}
      else
        [sidebar_rect, mr] =
          Layout.split(body_rect, :horizontal, [{:percentage, 30}, {:percentage, 70}])

        sidebar_widget =
          if state.active_tab == :diff do
            Sidebar.render_diff(
              state.diff.sidebar_entries,
              state.diff.sidebar_cursor,
              state.focus,
              state.theme
            )
          else
            Sidebar.render(
              state.sidebar.entries,
              state.sidebar.cursor,
              state.focus,
              state.theme
            )
          end

        {[{sidebar_widget, sidebar_rect}], mr}
      end

    base =
      [{render_mode_bar(state), header_rect}] ++
        sidebar_widgets ++
        [{render_footer(state), footer_rect}]

    base ++ render_main_area(state, main_rect) ++ Modals.render(state, frame)
  end

  @impl true
  def handle_event(%Paste{content: text}, %{modal: %{type: :none}} = state) do
    if Focus.focused?(state.focus, :main) do
      case state.selection.agent_mode do
        :pty ->
          forwarded = String.replace(text, "\n", "\r")
          {:noreply, forward_raw(state, forwarded)}

        _ ->
          chars = String.length(text)

          {:noreply,
           flash_status(
             %{state | input_buffer: state.input_buffer <> text, paste_mode: false},
             "Pasted #{chars} chars"
           )}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_event(%Key{code: "c", kind: "press", modifiers: ["ctrl"]}, state) do
    if Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty do
      {:noreply, forward_raw(state, "\x03")}
    else
      {:stop, state}
    end
  end

  def handle_event(%ExRatatui.Event.Resize{width: w, height: h}, state) do
    if state.refs.resize, do: Process.cancel_timer(state.refs.resize)
    ref = Process.send_after(self(), {:apply_resize, w, h}, 50)
    {:noreply, %{state | refs: %{state.refs | resize: ref}, term_size: {w, h}}}
  end

  def handle_event(%ExRatatui.Event.FocusGained{}, state), do: {:noreply, state, [render?: false]}

  def handle_event(%ExRatatui.Event.FocusLost{}, state), do: {:noreply, state, [render?: false]}

  # ── Mouse events ─────────────────────────────────────────────────────────────

  # Scroll in whichever pane the cursor is over.
  def handle_event(%Mouse{kind: "scroll_up"} = ev, %{modal: %{type: :none}} = state) do
    {:noreply, mouse_scroll(state, ev, -3)}
  end

  def handle_event(%Mouse{kind: "scroll_down"} = ev, %{modal: %{type: :none}} = state) do
    {:noreply, mouse_scroll(state, ev, 3)}
  end

  # Left click: focus the pane under the pointer.
  def handle_event(
        %Mouse{kind: "down", button: "left", x: x, y: _y},
        %{modal: %{type: :none}} = state
      ) do
    {term_w, _} = state.term_size || {80, 24}
    sidebar_width = if state.sidebar.collapsed, do: 0, else: round(term_w * 0.30)

    new_focus =
      if x < sidebar_width do
        Focus.new([:sidebar, :main])
      else
        Focus.new([:main, :sidebar])
      end

    {:noreply, %{state | focus: new_focus}}
  end

  def handle_event(%Mouse{}, state), do: {:noreply, state}

  # Edit mode — a context file is open for editing.
  # These clauses must come BEFORE the modal/normal handlers.

  # Esc: flush any pending autosave and exit edit mode.
  def handle_event(%Key{code: "esc", kind: "press"}, %{editor: %{file: f}} = state)
      when not is_nil(f) do
    {:noreply, save_and_close_editing(state)}
  end

  # Every other keypress in edit mode: forward to textarea + arm a 500 ms autosave.
  def handle_event(%Key{kind: "press"} = key, %{editor: %{file: f}} = state)
      when not is_nil(f) do
    ExRatatui.textarea_handle_key(state.editor.ref, key.code, key.modifiers)
    if state.editor.autosave, do: Process.cancel_timer(state.editor.autosave)
    ref = Process.send_after(self(), :autosave, 500)
    {:noreply, %{state | editor: %{state.editor | autosave: ref}}}
  end

  def handle_event(%Key{code: "esc", kind: "press"}, %{modal: %{type: :theme_picker}} = state) do
    {:noreply,
     %{
       state
       | modal: %{state.modal | type: :none},
         theme: state.modal.theme_picker.before
     }}
  end

  def handle_event(%Key{code: "esc", kind: "press"}, %{modal: %{type: modal}} = state)
      when modal != :none do
    {:noreply, flash_status(%{state | modal: %{state.modal | type: :none}}, "Cancelled")}
  end

  # Modal-specific event handling

  def handle_event(
        %Key{code: "enter", kind: "press"},
        %{modal: %{type: :confirm_delete}} = state
      ),
      do: {:noreply, do_delete(state)}

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: %{type: :new_name}} = state),
    do: {:noreply, confirm_name(state)}

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: %{type: :source_picker}} = state),
    do: {:noreply, confirm_source(state)}

  def handle_event(
        %Key{code: "enter", kind: "press"},
        %{modal: %{type: :integration_item_id}} = state
      ),
      do: {:noreply, confirm_integration_item_id(state)}

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: %{type: :new_dir}} = state),
    do: {:noreply, confirm_dir(state)}

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: %{type: :palette}} = state),
    do: {:noreply, execute_palette_action(state)}

  def handle_event(
        %Key{code: "enter", kind: "press"},
        %{modal: %{type: :new_context_file}} = state
      ),
      do: {:noreply, confirm_context_file(state)}

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: %{type: :theme_picker}} = state),
    do: {:noreply, apply_theme_picker(state)}

  def handle_event(
        %Key{code: "enter", kind: "press"},
        %{modal: %{type: :service_auth_url}} = state
      ),
      do: {:noreply, check_auth_and_proceed(state)}

  def handle_event(
        %Key{code: "enter", kind: "press"},
        %{modal: %{type: :service_guided_token}} = state
      ),
      do: {:noreply, confirm_service_guided_token(state)}

  def handle_event(
        %Key{code: "enter", kind: "press"},
        %{modal: %{type: :service_setup}} = state
      ) do
    services = Modals.setup_services()
    service = Enum.at(services, state.modal.service_setup.cursor)
    {:noreply, start_service_auth(state, service, :standalone)}
  end

  def handle_event(%Key{code: "r", kind: "press"}, %{modal: %{type: :service_setup}} = state) do
    services = Modals.setup_services()
    service = Enum.at(services, state.modal.service_setup.cursor)

    if Codrift.OAuth.connected?(service) do
      Codrift.OAuth.revoke_token(service)
      {:noreply, flash_status(state, "Revoked #{service} token")}
    else
      {:noreply, flash_status(state, "#{service} is not connected")}
    end
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: %{type: :service_setup}} = state) do
    cursor = max(state.modal.service_setup.cursor - 1, 0)
    {:noreply, %{state | modal: %{state.modal | service_setup: %{cursor: cursor}}}}
  end

  def handle_event(
        %Key{code: "down", kind: "press"},
        %{modal: %{type: :service_setup}} = state
      ) do
    max_idx = length(Modals.setup_services()) - 1
    cursor = min(state.modal.service_setup.cursor + 1, max_idx)
    {:noreply, %{state | modal: %{state.modal | service_setup: %{cursor: cursor}}}}
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: %{type: :new_dir}} = state),
    do: {:noreply, DirPicker.move_cursor(state, -1)}

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: %{type: :new_dir}} = state),
    do: {:noreply, DirPicker.move_cursor(state, 1)}

  def handle_event(%Key{code: "tab", kind: "press"}, %{modal: %{type: :new_dir}} = state),
    do: {:noreply, DirPicker.complete(state)}

  def handle_event(
        %Key{code: "w", kind: "press"},
        %{modal: %{type: :new_dir, worktree_git: true}} = state
      ) do
    {:noreply,
     %{state | modal: %{state.modal | worktree_enabled: not state.modal.worktree_enabled}}}
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: %{type: :palette}} = state) do
    palette = state.modal.palette
    new_palette = %{palette | cursor: max(palette.cursor - 1, 0)}
    {:noreply, %{state | modal: %{state.modal | palette: new_palette}}}
  end

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: %{type: :palette}} = state) do
    palette = state.modal.palette
    max_idx = max(length(Modals.filter_actions(state.modal.actions, palette.filter)) - 1, 0)
    new_palette = %{palette | cursor: min(palette.cursor + 1, max_idx)}
    {:noreply, %{state | modal: %{state.modal | palette: new_palette}}}
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: %{type: :source_picker}} = state) do
    cursor = max(state.modal.source_picker.cursor - 1, 0)
    {:noreply, %{state | modal: %{state.modal | source_picker: %{cursor: cursor}}}}
  end

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: %{type: :source_picker}} = state) do
    max_idx = length(Modals.sources()) - 1
    cursor = min(state.modal.source_picker.cursor + 1, max_idx)
    {:noreply, %{state | modal: %{state.modal | source_picker: %{cursor: cursor}}}}
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: %{type: :theme_picker}} = state) do
    cursor = max(state.modal.theme_picker.cursor - 1, 0)
    theme = Enum.at(theme_picker_list(), cursor).theme

    {:noreply,
     %{
       state
       | modal: %{state.modal | theme_picker: %{state.modal.theme_picker | cursor: cursor}},
         theme: theme
     }}
  end

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: %{type: :theme_picker}} = state) do
    max_idx = length(theme_picker_list()) - 1
    cursor = min(state.modal.theme_picker.cursor + 1, max_idx)
    theme = Enum.at(theme_picker_list(), cursor).theme

    {:noreply,
     %{
       state
       | modal: %{state.modal | theme_picker: %{state.modal.theme_picker | cursor: cursor}},
         theme: theme
     }}
  end

  def handle_event(%Key{code: code, kind: "press"}, %{modal: %{type: modal}} = state)
      when modal in [
             :new_name,
             :new_dir,
             :palette,
             :new_context_file,
             :integration_item_id,
             :service_guided_token
           ] and byte_size(code) == 1 do
    ExRatatui.text_input_handle_key(state.modal.input, code)
    {:noreply, sync_modal(state, modal)}
  end

  def handle_event(%Key{code: code, kind: "press"}, %{modal: %{type: modal}} = state)
      when modal in [
             :new_name,
             :new_dir,
             :palette,
             :new_context_file,
             :integration_item_id,
             :service_guided_token
           ] and code in ["backspace", "delete", "left", "right", "home", "end"] do
    ExRatatui.text_input_handle_key(state.modal.input, code)
    {:noreply, sync_modal(state, modal)}
  end

  # Normal mode — no modal open.
  #
  # Focus determines routing:
  #   :sidebar → j/k navigate, letters are management shortcuts
  #   :main    → all printable chars go to the agent input buffer

  # Shift+Tab (back_tab) and Tab+Shift/Tab+Ctrl all cycle focus regardless of pane.
  def handle_event(%Key{code: "back_tab", kind: "press"} = key, %{modal: %{type: :none}} = state) do
    {new_focus, _} = Focus.handle_key(state.focus, key)
    {:noreply, %{state | focus: new_focus, input_buffer: ""}}
  end

  def handle_event(
        %Key{code: "tab", kind: "press", modifiers: modifiers},
        %{modal: %{type: :none}} = state
      )
      when modifiers != [] do
    tab_key = %Key{code: "tab", kind: "press", modifiers: []}
    {new_focus, _} = Focus.handle_key(state.focus, tab_key)
    {:noreply, %{state | focus: new_focus, input_buffer: ""}}
  end

  # Plain Tab (no modifiers): insert \t in main non-PTY, forward in PTY, cycle from sidebar.
  def handle_event(%Key{code: "tab", kind: "press"} = key, %{modal: %{type: :none}} = state) do
    cond do
      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\t")}

      Focus.focused?(state.focus, :main) ->
        {:noreply, %{state | input_buffer: state.input_buffer <> "\t"}}

      true ->
        {new_focus, _} = Focus.handle_key(state.focus, key)
        {:noreply, %{state | focus: new_focus, input_buffer: ""}}
    end
  end

  def handle_event(
        %Key{code: "d", kind: "press", modifiers: ["ctrl"]},
        %{modal: %{type: :none}} = state
      ) do
    cond do
      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\x04")}

      state.active_tab == :diff ->
        {:noreply, %{state | diff: %{state.diff | scroll: state.diff.scroll + 10}}}

      true ->
        {:noreply, %{state | main_scroll: state.main_scroll + 10}}
    end
  end

  def handle_event(
        %Key{code: "u", kind: "press", modifiers: ["ctrl"]},
        %{modal: %{type: :none}} = state
      ) do
    cond do
      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\x15")}

      state.active_tab == :diff ->
        {:noreply, %{state | diff: %{state.diff | scroll: max(state.diff.scroll - 10, 0)}}}

      true ->
        {:noreply, %{state | main_scroll: max(state.main_scroll - 10, 0)}}
    end
  end

  # Ctrl+V toggles paste accumulation mode (non-PTY main pane).
  # In paste mode, Enter inserts \n instead of submitting, so pasted
  # multi-line text lands in the buffer as one block. Press Ctrl+V again
  # to exit paste mode (Enter reverts to submitting).
  def handle_event(
        %Key{code: "v", kind: "press", modifiers: ["ctrl"]},
        %{modal: %{type: :none}} = state
      ) do
    if Focus.focused?(state.focus, :main) and state.selection.agent_mode != :pty do
      new_mode = not state.paste_mode
      msg = if new_mode, do: "Paste mode ON — Enter inserts newline", else: "Paste mode OFF"
      {:noreply, flash_status(%{state | paste_mode: new_mode}, msg)}
    else
      action = Map.get(state.kb.reverse, "ctrl+v")
      dispatch_sidebar_action(action, state)
    end
  end

  # Generic ctrl-key handler — dispatches configured actions (toggle_sidebar, palette, …).
  # Must come after ctrl+c/d/u/v which have PTY-forwarding logic.
  def handle_event(
        %Key{code: code, kind: "press", modifiers: ["ctrl"]},
        %{modal: %{type: :none}} = state
      ) do
    action = Map.get(state.kb.reverse, "ctrl+#{code}")
    dispatch_sidebar_action(action, state)
  end

  def handle_event(
        %Key{code: "enter", kind: "press", modifiers: ["shift"]},
        %{modal: %{type: :none}} = state
      ) do
    if Focus.focused?(state.focus, :main) do
      case state.selection.agent_mode do
        :pty -> {:noreply, forward_raw(state, "\r")}
        _ -> {:noreply, %{state | input_buffer: state.input_buffer <> "\n"}}
      end
    else
      {:noreply, state}
    end
  end

  # Main pane focused — route to agent based on its mode.
  # In paste_mode, Enter inserts \n so multi-line pastes land as one block.
  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: %{type: :none}} = state) do
    if Focus.focused?(state.focus, :main) do
      case state.selection.agent_mode do
        :pty ->
          {:noreply, forward_raw(state, "\r")}

        _ when state.paste_mode ->
          {:noreply, %{state | input_buffer: state.input_buffer <> "\n"}}

        _ ->
          {:noreply, send_agent_input(state)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_event(%Key{code: "esc", kind: "press"}, %{modal: %{type: :none}} = state) do
    if Focus.focused?(state.focus, :main) do
      case state.selection.agent_mode do
        :pty -> {:noreply, forward_raw(state, "\e")}
        _ -> {:noreply, flash_status(%{state | input_buffer: ""}, "Input cleared")}
      end
    else
      {:noreply, state}
    end
  end

  def handle_event(%Key{code: "backspace", kind: "press"}, %{modal: %{type: :none}} = state) do
    if Focus.focused?(state.focus, :main) do
      case state.selection.agent_mode do
        :pty ->
          {:noreply, forward_raw(state, "\x7f")}

        _ ->
          new_buf = String.slice(state.input_buffer, 0..-2//1)
          {:noreply, %{state | input_buffer: new_buf}}
      end
    else
      {:noreply, state}
    end
  end

  # Generic single-character key handler.
  #
  # Routing priority:
  #   1. Configured quit key (single-char override only) → always quit
  #   2. Main pane + PTY agent → forward raw to PTY
  #   3. Main pane + non-PTY + edit_context key on a context_file → open editor
  #   4. Main pane + non-PTY → append to input buffer
  #   5. Sidebar focused → dispatch via configured action
  def handle_event(%Key{code: code, kind: "press"}, %{modal: %{type: :none}} = state)
      when byte_size(code) == 1 do
    action = Map.get(state.kb.reverse, code)
    focus = Focus.focused?(state.focus, :main)
    dispatch_char(action, code, focus, state)
  end

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: %{type: :none}} = state) do
    cond do
      Focus.focused?(state.focus, :sidebar) ->
        {:noreply, navigate(state, 1)}

      state.active_tab == :diff ->
        {:noreply, %{state | diff: %{state.diff | scroll: state.diff.scroll + 3}}}

      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\e[B")}

      Focus.focused?(state.focus, :main) ->
        {:noreply, %{state | main_scroll: state.main_scroll + 3}}

      true ->
        {:noreply, state}
    end
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: %{type: :none}} = state) do
    cond do
      Focus.focused?(state.focus, :sidebar) ->
        {:noreply, navigate(state, -1)}

      state.active_tab == :diff ->
        {:noreply, %{state | diff: %{state.diff | scroll: max(state.diff.scroll - 3, 0)}}}

      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\e[A")}

      Focus.focused?(state.focus, :main) ->
        {:noreply, %{state | main_scroll: max(state.main_scroll - 3, 0)}}

      true ->
        {:noreply, state}
    end
  end

  def handle_event(%Key{code: "right", kind: "press"}, %{modal: %{type: :none}} = state) do
    if Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty do
      {:noreply, forward_raw(state, "\e[C")}
    else
      {:noreply, state}
    end
  end

  def handle_event(%Key{code: "left", kind: "press"}, %{modal: %{type: :none}} = state) do
    if Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty do
      {:noreply, forward_raw(state, "\e[D")}
    else
      {:noreply, state}
    end
  end

  def handle_event(%Key{code: code, kind: "press"}, %{modal: %{type: :none}} = state)
      when byte_size(code) > 1 and byte_size(code) <= 4 do
    if String.length(code) == 1 do
      focus = Focus.focused?(state.focus, :main)
      dispatch_char(nil, code, focus, state)
    else
      {:noreply, state}
    end
  end

  def handle_event(_, state), do: {:noreply, state}

  # ── Action dispatcher ─────────────────────────────────────────────────────────
  # Handles each action atom, called from both the sidebar key path and the
  # generic ctrl-key handler.

  defp dispatch_char(:quit, _code, _main_focused, state) do
    save_all_sessions(state)
    {:stop, state}
  end

  defp dispatch_char(_action, code, true, %{selection: %{agent_mode: :pty}} = state),
    do: {:noreply, forward_raw(state, code)}

  defp dispatch_char(:edit_context, code, true, state) do
    case state.cursor_info do
      %{type: :context_file, path: path} -> {:noreply, start_editing(state, path)}
      _ -> {:noreply, %{state | input_buffer: state.input_buffer <> code}}
    end
  end

  defp dispatch_char(_action, code, true, state),
    do: {:noreply, %{state | input_buffer: state.input_buffer <> code}}

  defp dispatch_char(nil, "W", false, state),
    do: {:noreply, toggle_dir_worktree_at_cursor(state)}

  defp dispatch_char(action, _code, false, state),
    do: dispatch_sidebar_action(action, state)

  defp dispatch_sidebar_action(:navigate_down, state),
    do: {:noreply, navigate(state, 1)}

  defp dispatch_sidebar_action(:navigate_up, state),
    do: {:noreply, navigate(state, -1)}

  defp dispatch_sidebar_action(:context_mode, state) do
    {:noreply, %{state | active_tab: :context, main_scroll: 0} |> update_context_from_cursor()}
  end

  defp dispatch_sidebar_action(:diff_mode, state) do
    new_state = %{
      state
      | active_tab: :diff,
        main_scroll: 0,
        diff: %{state.diff | scroll: 0, sidebar_cursor: 0, view_mode: :unified}
    }

    {:noreply, refresh_diff(new_state)}
  end

  defp dispatch_sidebar_action(:toggle_diff_view, %{active_tab: :diff} = state) do
    new_mode = if state.diff.view_mode == :unified, do: :split, else: :unified
    {:noreply, %{state | diff: %{state.diff | view_mode: new_mode, scroll: 0}}}
  end

  defp dispatch_sidebar_action(:toggle_diff_view, state), do: {:noreply, state}

  defp dispatch_sidebar_action(:diff_all_files, %{active_tab: :diff} = state),
    do: {:noreply, %{state | diff: %{state.diff | sidebar_cursor: 0, scroll: 0}}}

  defp dispatch_sidebar_action(:diff_all_files, state), do: {:noreply, state}

  defp dispatch_sidebar_action(:add_dir, state),
    do: {:noreply, open_add_dir_modal(state)}

  defp dispatch_sidebar_action(:start_agent, state),
    do: {:noreply, start_agent_at_cursor(state, Claude)}

  defp dispatch_sidebar_action(:start_terminal, state),
    do: {:noreply, start_agent_at_cursor(state, Terminal)}

  defp dispatch_sidebar_action(:new_context, state),
    do: {:noreply, open_new_context_file_modal(state)}

  defp dispatch_sidebar_action(:delete, state),
    do: {:noreply, open_delete_confirm(state)}

  defp dispatch_sidebar_action(:edit_context, state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:context_file, _, path, _} -> {:noreply, start_editing(state, path)}
      _ -> {:noreply, state}
    end
  end

  defp dispatch_sidebar_action(:refresh, state),
    do: {:noreply, refresh_current(state)}

  defp dispatch_sidebar_action(:status_next, state),
    do: {:noreply, cycle_initiative_status(state, :next)}

  defp dispatch_sidebar_action(:status_prev, state),
    do: {:noreply, cycle_initiative_status(state, :prev)}

  defp dispatch_sidebar_action(:new_initiative, state) do
    {:noreply, open_source_picker(state)}
  end

  defp dispatch_sidebar_action(:toggle_sidebar, state),
    do: {:noreply, toggle_sidebar(state)}

  defp dispatch_sidebar_action(:palette, state) do
    ExRatatui.text_input_set_value(state.modal.input, "")

    {:noreply,
     %{state | modal: %{state.modal | type: :palette, palette: %{cursor: 0, filter: ""}}}}
  end

  defp dispatch_sidebar_action(:quit, state) do
    save_all_sessions(state)
    {:stop, state}
  end

  # Unknown or unbound key — no-op.
  defp dispatch_sidebar_action(_, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_output, agent_id, data}, state) do
    {w, h} = state.pane_size

    screen = Map.get(state.agents.screens, agent_id, VT100.new(w, h))

    updated = VT100.process(screen, data)
    new_screens = Map.put(state.agents.screens, agent_id, updated)

    outputs =
      Map.update(state.agents.outputs, agent_id, [data], fn buf ->
        Enum.take([data | buf], 200)
      end)

    selected = agent_id == state.selection.agent_id

    new_scroll =
      if selected,
        # VT100 screen is sized exactly to the pane; it manages its own viewport.
        # Always snap to 0 so new output shows the current terminal state.
        do: 0,
        else: state.main_scroll

    new_state = %{
      state
      | agents: %{state.agents | screens: new_screens, outputs: outputs},
        main_scroll: new_scroll
    }

    {:noreply, new_state, [render?: selected]}
  end

  def handle_info({:apply_resize, w, h}, state) do
    {pane_w, pane_h} = calc_pane_size(w, h, state.sidebar.collapsed)

    if {pane_w, pane_h} == state.pane_size do
      {:noreply, %{state | refs: %{state.refs | resize: nil}}, [render?: false]}
    else
      new_screens =
        Map.new(state.agents.screens, fn {id, screen} ->
          {id, VT100.resize(screen, pane_w, pane_h)}
        end)

      resize_selected_pty(state.selection.agent_id, pane_w, pane_h)

      {:noreply,
       %{
         state
         | pane_size: {pane_w, pane_h},
           agents: %{state.agents | screens: new_screens},
           main_scroll: 0,
           refs: %{state.refs | resize: nil}
       }}
    end
  end

  def handle_info({:agent_ready, agent_id}, state) do
    send_initiative_context_prompt(agent_id)
    {:noreply, reload_sidebar(flash_status(state, "Agent #{String.slice(agent_id, 0, 8)} ready"))}
  end

  def handle_info({:agent_started, dir}, state) do
    {:noreply, reload_sidebar(flash_status(state, "Agent started in #{Paths.compact(dir)}"))}
  end

  def handle_info({:agent_start_failed, reason}, state) do
    {:noreply, flash_status(state, "Failed: #{inspect(reason)}")}
  end

  def handle_info({:agent_stopped, agent_id, 0}, state) do
    short = String.slice(agent_id, 0, 8)
    Codrift.SessionStore.delete_by_agent(agent_id)

    new_state = %{
      state
      | agents: %{state.agents | subscribed: MapSet.delete(state.agents.subscribed, agent_id)}
    }

    {:noreply, reload_sidebar(flash_status(new_state, "Agent #{short} finished"))}
  end

  def handle_info({:agent_stopped, agent_id, code}, state) do
    short = String.slice(agent_id, 0, 8)
    Codrift.SessionStore.delete_by_agent(agent_id)

    new_state = %{
      state
      | agents: %{state.agents | subscribed: MapSet.delete(state.agents.subscribed, agent_id)}
    }

    {:noreply,
     reload_sidebar(
       flash_status(new_state, "! Agent #{short} exited #{code} — see output pane", 4000)
     )}
  end

  # Ink optimizes away the repaint when terminal dimensions haven't changed.
  # Force a full \e[2J + redraw by briefly sending a different size, then
  # restoring the correct one. Two distinct SIGWINCHes guarantee a full clear.
  def handle_info({:nudge_agent, agent_id, w, h}, state) do
    state = %{state | refs: %{state.refs | nudge: nil}}

    if agent_id == state.selection.agent_id do
      case AgentSupervisor.find_agent(agent_id) do
        {:ok, pid} ->
          if state.refs.restore, do: Process.cancel_timer(state.refs.restore)
          AgentProcess.resize(pid, max(w - 1, 1), h)
          restore_ref = Process.send_after(self(), {:restore_agent_size, agent_id, w, h}, 60)
          {:noreply, %{state | refs: %{state.refs | restore: restore_ref}}, [render?: false]}

        _ ->
          {:noreply, state, [render?: false]}
      end
    else
      {:noreply, state, [render?: false]}
    end
  end

  def handle_info({:restore_agent_size, agent_id, w, h}, state) do
    state = %{state | refs: %{state.refs | restore: nil}}

    if agent_id == state.selection.agent_id do
      case AgentSupervisor.find_agent(agent_id) do
        {:ok, pid} ->
          AgentProcess.resize(pid, w, h)
          # After the restore repaint completes, send \r to force Claude Code to
          # redraw its input prompt.  This is the "special character" that puts
          # the cursor at the input line.  Only fires when Claude is at the
          # prompt (awaiting_input) — harmless no-op otherwise.
          Process.send_after(self(), {:input_nudge, agent_id}, 100)
          {:noreply, state, [render?: false]}

        _ ->
          {:noreply, state, [render?: false]}
      end
    else
      {:noreply, state, [render?: false]}
    end
  end

  # Sends \r to Claude Code when it's sitting at the ❯ prompt.
  # This forces Ink to redraw the input line and positions the cursor correctly.
  # Terminal/shell agents must NOT receive this — they interpret \r as an empty
  # Enter keypress and print an extra prompt each time.
  def handle_info({:input_nudge, agent_id}, state) do
    maybe_nudge_agent(agent_id, state)
    {:noreply, state, [render?: false]}
  end

  def handle_info(:sidebar_tick, state) do
    ref = Process.send_after(self(), :sidebar_tick, 2000)
    {:noreply, reload_sidebar(%{state | refs: %{state.refs | sidebar_tick: ref}})}
  end

  # Autosave fires 500 ms after the last keystroke while editing a file.
  def handle_info(:autosave, %{editor: %{file: nil}} = state) do
    {:noreply, state}
  end

  def handle_info(:autosave, state) do
    # Silent save — don't interrupt the editing status hint.
    # Only surface errors. Guard against writing outside the managed context tree.
    new_state =
      if Store.context_file_path?(state.editor.file) do
        content = ExRatatui.textarea_get_value(state.editor.ref)

        case File.write(state.editor.file, content) do
          :ok ->
            %{state | editor: %{state.editor | autosave: nil}}

          {:error, r} ->
            %{
              state
              | editor: %{state.editor | autosave: nil},
                status: "Autosave failed: #{inspect(r)}"
            }
        end
      else
        %{
          state
          | editor: %{state.editor | autosave: nil},
            status: "Autosave refused: path outside Codrift folder"
        }
      end

    {:noreply, new_state}
  end

  def handle_info({:device_auth_complete, service, return_to}, state) do
    base =
      if state.modal.type == :service_device_flow,
        do: %{state | modal: %{state.modal | type: :none}},
        else: state

    new_state =
      case return_to do
        :source_picker ->
          flash_status(
            reload_sidebar(base),
            "#{service} connected — select it in the source picker to import"
          )

        :standalone ->
          flash_status(
            %{
              base
              | modal: %{
                  base.modal
                  | type: :service_setup,
                    context: :standalone,
                    service_setup: %{cursor: 0}
                }
            },
            "#{service} connected"
          )
      end

    {:noreply, new_state}
  end

  def handle_info({:device_auth_failed, service, reason, _return_to}, state) do
    base =
      if state.modal.type == :service_device_flow,
        do: %{state | modal: %{state.modal | type: :none}},
        else: state

    {:noreply, flash_status(base, "#{service} auth failed: #{reason}")}
  end

  def handle_info(:reset_status, state) do
    {:noreply,
     %{
       state
       | status: build_default_status(state.kb.bindings),
         refs: %{state.refs | status_timer: nil}
     }}
  end

  # Auto-restart Claude agents that were running when the TUI last exited.
  # Deduplicates by (initiative_id, dir): keeps the last-saved agent per slot
  # and deletes any extras so they don't accumulate across restarts.
  def handle_info(:autostart_sessions, state) do
    sessions = Codrift.SessionStore.list_all()
    valid_ids = Store.list() |> Enum.map(& &1.id)
    Codrift.SessionStore.prune_deleted_initiatives(valid_ids)

    # Group by slot, keep one agent ID per slot, delete the rest.
    {to_start, to_delete} =
      sessions
      |> Enum.group_by(fn {_agent_id, initiative_id, dir, _uuid} -> {initiative_id, dir} end)
      |> Enum.reduce({[], []}, fn {_slot, entries}, {keep, drop} ->
        [head | tail] = entries
        {[head | keep], tail ++ drop}
      end)

    Enum.each(to_delete, fn {agent_id, _initiative_id, _dir, _uuid} ->
      Codrift.SessionStore.delete_by_agent(agent_id)
    end)

    new_state =
      Enum.reduce(to_start, state, fn {agent_id, initiative_id, dir, _uuid}, acc ->
        case Store.get(initiative_id) do
          {:ok, _initiative} ->
            do_start_agent(acc, initiative_id, dir, Claude, agent_id)

          _ ->
            acc
        end
      end)

    {:noreply, new_state}
  end

  def handle_info({:update_available, latest}, state) do
    {:noreply, flash_status(state, "codrift #{latest} available — run `codrift update`", 8000)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp save_all_sessions(state) do
    for agent_id <- MapSet.to_list(state.agents.subscribed) do
      try do
        with {:ok, pid} <- AgentSupervisor.find_agent(agent_id),
             status = AgentProcess.status(pid),
             # Only persist Claude sessions — Terminal and other adapters don't
             # use --resume and should never be auto-restarted on next launch.
             true <- status.adapter == Claude,
             uuid when not is_nil(uuid) <- AgentProcess.session_uuid(pid) do
          Codrift.SessionStore.save(agent_id, status.initiative_id, status.dir, uuid)
        end
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp open_source_picker(state) do
    %{
      state
      | modal: %{
          state.modal
          | type: :source_picker,
            context: :source_for_new,
            source_picker: %{cursor: 0}
        },
        status: "↑/↓: choose source  Enter: confirm  Esc: cancel"
    }
  end

  # :new_name is only reached from source_picker "new" — always goes straight to :new_dir
  defp confirm_name(state) do
    name = String.trim(ExRatatui.text_input_get_value(state.modal.input))

    if name == "" do
      flash_status(state, "Name cannot be empty")
    else
      ExRatatui.text_input_set_value(state.modal.input, "")

      %{
        state
        | modal: %{
            state.modal
            | type: :new_dir,
              context: {:creating, name},
              dir_picker: %{suggestions: DirPicker.suggestions(""), cursor: 0}
          },
          status: "↑/↓: navigate  Tab: complete  Enter: create  Esc: cancel"
      }
    end
  end

  defp confirm_source(state) do
    cursor = state.modal.source_picker.cursor
    {service, _label} = Enum.at(Modals.sources(), cursor)

    case service do
      "new" ->
        ExRatatui.text_input_set_value(state.modal.input, "")
        %{state | modal: %{state.modal | type: :new_name, context: :creating_blank}}

      service ->
        if service_ready?(service) do
          ExRatatui.text_input_set_value(state.modal.input, "")

          %{
            state
            | modal: %{
                state.modal
                | type: :integration_item_id,
                  context: {:importing, service}
              },
              status: "Enter item ID for #{service}  Enter: import  Esc: cancel"
          }
        else
          start_service_auth(state, service, :source_picker)
        end
    end
  end

  # Returns true when the service has a stored token or uses only env-var auth (no OAuth config)
  defp service_ready?(service) do
    Codrift.OAuth.connected?(service) or
      match?({:error, _}, OAuthConfig.get(service))
  end

  # Starts the appropriate auth flow for a service, carrying `return_to` so
  # the completed auth lands the user back in the right place.
  defp start_service_auth(state, service, return_to) do
    tag = context_tag(return_to)

    case Codrift.OAuth.start_flow(service) do
      {:ok, %{flow: :pkce_browser, auth_url: url}} ->
        %{
          state
          | modal: %{
              state.modal
              | type: :service_auth_url,
                context: {tag, service, url}
            },
            status: "Open the URL in your browser, then press Enter to continue"
        }

      {:ok,
       %{
         flow: :device_flow,
         user_code: user_code,
         verification_uri: verification_uri,
         device_code: device_code,
         expires_in: expires_in,
         interval: interval
       }} ->
        expires_at = System.os_time(:second) + expires_in

        Codrift.OAuth.poll_device_auth(
          self(),
          service,
          device_code,
          expires_at,
          interval,
          return_to
        )

        %{
          state
          | modal: %{
              state.modal
              | type: :service_device_flow,
                context: {tag, service, user_code, verification_uri}
            },
            status: "Visit #{verification_uri} and enter #{user_code}"
        }

      {:ok, %{flow: :guided_token, instructions: instructions}} ->
        ExRatatui.text_input_set_value(state.modal.input, "")

        %{
          state
          | modal: %{
              state.modal
              | type: :service_guided_token,
                context: {tag, service, instructions}
            },
            status: "Paste your #{service} token and press Enter"
        }

      {:error, reason} ->
        flash_status(state, "Cannot start auth for #{service}: #{reason}")
    end
  end

  defp context_tag(:source_picker), do: :connecting_for_import
  defp context_tag(:standalone), do: :connecting_standalone

  # Called when the user pressed Enter on :service_auth_url — check if connected yet.
  defp check_auth_and_proceed(state) do
    case state.modal.context do
      {:connecting_for_import, service, _url} ->
        if Codrift.OAuth.connected?(service) do
          ExRatatui.text_input_set_value(state.modal.input, "")

          flash_status(
            %{
              state
              | modal: %{
                  state.modal
                  | type: :integration_item_id,
                    context: {:importing, service}
                }
            },
            "Connected to #{service} — enter the item ID"
          )
        else
          flash_status(
            state,
            "Still waiting for authorization — complete it in the browser first"
          )
        end

      {:connecting_standalone, service, _url} ->
        if Codrift.OAuth.connected?(service) do
          flash_status(
            %{
              state
              | modal: %{
                  state.modal
                  | type: :service_setup,
                    context: :standalone,
                    service_setup: %{cursor: 0}
                }
            },
            "#{service} connected"
          )
        else
          flash_status(
            state,
            "Still waiting for authorization — complete it in the browser first"
          )
        end
    end
  end

  defp confirm_service_guided_token(state) do
    token = String.trim(ExRatatui.text_input_get_value(state.modal.input))

    if token == "" do
      flash_status(state, "Token cannot be empty")
    else
      {tag, service, _instructions} = state.modal.context

      case Codrift.OAuth.save_guided_token(service, token) do
        :ok ->
          ExRatatui.text_input_set_value(state.modal.input, "")
          navigate_after_token_save(state, tag, service)

        {:error, reason} ->
          flash_status(state, "Invalid token: #{reason}")
      end
    end
  end

  defp navigate_after_token_save(state, :connecting_for_import, service) do
    flash_status(
      %{
        state
        | modal: %{state.modal | type: :integration_item_id, context: {:importing, service}}
      },
      "Connected to #{service} — enter the item ID"
    )
  end

  defp navigate_after_token_save(state, :connecting_standalone, service) do
    flash_status(
      %{
        state
        | modal: %{
            state.modal
            | type: :service_setup,
              context: :standalone,
              service_setup: %{cursor: 0}
          }
      },
      "#{service} connected"
    )
  end

  defp confirm_integration_item_id(state) do
    item_id = String.trim(ExRatatui.text_input_get_value(state.modal.input))
    {:importing, service} = state.modal.context

    if item_id == "" do
      flash_status(state, "Item ID cannot be empty")
    else
      state = flash_status(state, "Importing #{service}/#{item_id}…")

      case import_integration_item(service, item_id) do
        {:ok, initiative} ->
          ExRatatui.text_input_set_value(state.modal.input, "")
          state |> reload_sidebar() |> after_import(initiative)

        {:error, reason} ->
          flash_status(state, "Import failed: #{inspect(reason)}")
      end
    end
  end

  defp after_import(state, initiative) do
    flash_status(
      %{
        state
        | modal: %{
            state.modal
            | type: :new_dir,
              context: {:add_dir, initiative.id},
              dir_picker: %{suggestions: DirPicker.suggestions(""), cursor: 0}
          },
          selection: %{state.selection | initiative_id: initiative.id}
      },
      "Imported '#{initiative.name}' — add a directory or Esc to skip"
    )
  end

  defp import_integration_item(service, item_id) do
    with {:ok, adapter} <- Codrift.Integration.adapter_for(service),
         {:ok, item} <- adapter.get_item(item_id, []),
         {:ok, initiative} <- Store.create(item.title, []) do
      status = Codrift.Integration.map_item_status(item.status)
      Store.set_status(initiative.id, status)
      Store.link_integration(initiative.id, service, item_id)

      Codrift.Integration.write_integration_files(
        initiative.id,
        service,
        item_id,
        adapter.to_initiative_context(item)
      )

      {:ok, %{initiative | status: status, integration: %{service: service, item_id: item_id}}}
    end
  end

  defp confirm_dir(%{modal: %{context: {:creating, name}}} = state) do
    dir = typed_dir(state)

    with true <- File.dir?(dir),
         {:ok, initiative} <- Store.create(name, [dir]) do
      state
      |> reload_sidebar()
      |> then(fn s ->
        flash_status(
          %{
            s
            | modal: %{s.modal | type: :none, context: nil},
              selection: %{s.selection | initiative_id: initiative.id}
          },
          "Created '#{name}'"
        )
      end)
    else
      false ->
        flash_status(state, "Directory does not exist: #{Paths.compact(dir)}")

      {:error, reason} ->
        flash_status(
          %{state | modal: %{state.modal | type: :none, context: nil}},
          "Create failed: #{inspect(reason)}"
        )
    end
  end

  defp confirm_dir(%{modal: %{context: {:add_dir, initiative_id}}} = state) do
    dir = typed_dir(state)

    worktree_enabled = state.modal.worktree_git and state.modal.worktree_enabled

    with true <- File.dir?(dir),
         {:ok, _} <- Store.add_dir(initiative_id, dir, worktree_enabled: worktree_enabled) do
      suffix = if worktree_enabled, do: " (worktree)", else: ""

      state
      |> reload_sidebar()
      |> then(fn s ->
        flash_status(
          %{s | modal: %{s.modal | type: :none, context: nil}},
          "Added: #{Paths.compact(dir)}#{suffix}"
        )
      end)
    else
      false ->
        flash_status(state, "Directory does not exist: #{Paths.compact(dir)}")

      {:error, reason} ->
        flash_status(
          %{state | modal: %{state.modal | type: :none, context: nil}},
          "Failed: #{inspect(reason)}"
        )
    end
  end

  defp confirm_dir(state), do: %{state | modal: %{state.modal | type: :none, context: nil}}

  defp typed_dir(state) do
    state.modal.input |> ExRatatui.text_input_get_value() |> String.trim() |> Path.expand()
  end

  defp open_add_dir_modal(state) do
    initiative_id =
      case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
        {:initiative, id, _, _, _, _} -> id
        {:dir, id, _, _, _} -> id
        {:context_dir, id, _, _} -> id
        {:context_file, id, _, _} -> id
        _ -> state.selection.initiative_id
      end

    if is_nil(initiative_id) do
      flash_status(state, "Navigate to an initiative or directory first")
    else
      worktree_default =
        case Store.get(initiative_id) do
          {:ok, initiative} -> initiative.worktree_default
          _ -> false
        end

      ExRatatui.text_input_set_value(state.modal.input, "")

      %{
        state
        | modal: %{
            state.modal
            | type: :new_dir,
              context: {:add_dir, initiative_id},
              dir_picker: %{suggestions: DirPicker.suggestions(""), cursor: 0},
              worktree_git: false,
              worktree_enabled: worktree_default
          },
          status: "↑/↓: navigate  Tab: complete  Enter: add  Esc: cancel"
      }
    end
  end

  defp open_delete_confirm(state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:initiative, id, name, _, _, _} ->
        %{
          state
          | modal: %{state.modal | type: :confirm_delete, context: {:delete_initiative, id, name}}
        }

      {:dir, initiative_id, dir, _, _} ->
        %{
          state
          | modal: %{
              state.modal
              | type: :confirm_delete,
                context: {:remove_dir, initiative_id, dir}
            }
        }

      {:context_dir, _, _, _} ->
        flash_status(state, "Press 'c' to create files in the context folder")

      {:context_file, _, path, name} ->
        %{
          state
          | modal: %{
              state.modal
              | type: :confirm_delete,
                context: {:delete_context_file, path, name}
            }
        }

      {:agent, agent_id, _, _} ->
        %{state | modal: %{state.modal | type: :confirm_delete, context: {:stop_agent, agent_id}}}

      nil ->
        flash_status(state, "Navigate to an item first")
    end
  end

  defp do_delete(%{modal: %{context: {:delete_initiative, id, name}}} = state) do
    case Store.delete(id) do
      :ok ->
        cleared =
          if state.selection.initiative_id == id, do: nil, else: state.selection.initiative_id

        state
        |> reload_sidebar()
        |> then(fn s ->
          flash_status(
            %{
              s
              | modal: %{s.modal | type: :none, context: nil},
                selection: %{s.selection | initiative_id: cleared},
                cursor_info: nil
            },
            "Deleted '#{name}'"
          )
        end)

      {:error, reason} ->
        flash_status(
          %{state | modal: %{state.modal | type: :none, context: nil}},
          "Delete failed: #{inspect(reason)}"
        )
    end
  end

  defp do_delete(%{modal: %{context: {:remove_dir, initiative_id, dir}}} = state) do
    case Store.remove_dir(initiative_id, dir) do
      {:ok, _} ->
        state
        |> reload_sidebar()
        |> then(fn s ->
          flash_status(
            %{s | modal: %{s.modal | type: :none, context: nil}, cursor_info: nil},
            "Removed: #{Paths.compact(dir)}"
          )
        end)

      {:error, reason} ->
        flash_status(
          %{state | modal: %{state.modal | type: :none, context: nil}},
          "Failed: #{inspect(reason)}"
        )
    end
  end

  defp do_delete(%{modal: %{context: {:delete_context_file, path, name}}} = state) do
    if Store.context_file_path?(path) do
      case File.rm(path) do
        :ok ->
          state
          |> reload_sidebar()
          |> update_context_from_cursor()
          |> then(
            &flash_status(
              %{&1 | modal: %{&1.modal | type: :none, context: nil}},
              "Deleted #{name}"
            )
          )

        {:error, reason} ->
          flash_status(
            %{state | modal: %{state.modal | type: :none, context: nil}},
            "Delete failed: #{inspect(reason)}"
          )
      end
    else
      flash_status(
        %{state | modal: %{state.modal | type: :none, context: nil}},
        "Refused: #{path} is outside the Codrift context folder"
      )
    end
  end

  defp do_delete(%{modal: %{context: {:stop_agent, agent_id}}} = state) do
    case AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} ->
        AgentSupervisor.stop_agent(pid)
        Codrift.SessionStore.delete_by_agent(agent_id)
        cleared = if state.selection.agent_id == agent_id, do: nil, else: state.selection.agent_id

        state
        |> reload_sidebar()
        |> then(fn s ->
          flash_status(
            %{
              s
              | modal: %{s.modal | type: :none, context: nil},
                selection: %{s.selection | agent_id: cleared}
            },
            "Agent stopped"
          )
        end)

      {:error, :not_found} ->
        flash_status(
          %{state | modal: %{state.modal | type: :none, context: nil}},
          "Agent not found"
        )
    end
  end

  defp execute_palette_action(state) do
    filtered = Modals.filter_actions(state.modal.actions, state.modal.palette.filter)

    case Enum.at(filtered, state.modal.palette.cursor) do
      nil -> %{state | modal: %{state.modal | type: :none}}
      %{id: id} -> do_palette_action(id, state)
    end
  end

  defp do_palette_action(:toggle_sidebar, state),
    do: toggle_sidebar(%{state | modal: %{state.modal | type: :none}})

  defp do_palette_action(:context_mode, state),
    do:
      %{state | modal: %{state.modal | type: :none}, active_tab: :context, main_scroll: 0}
      |> update_context_from_cursor()

  defp do_palette_action(:diff_mode, state) do
    refresh_diff(%{
      state
      | modal: %{state.modal | type: :none},
        active_tab: :diff,
        main_scroll: 0,
        diff: %{state.diff | scroll: 0, sidebar_cursor: 0, view_mode: :unified}
    })
  end

  defp do_palette_action(:toggle_diff_view, state) do
    new_mode = if state.diff.view_mode == :unified, do: :split, else: :unified

    %{
      state
      | modal: %{state.modal | type: :none},
        diff: %{state.diff | view_mode: new_mode, scroll: 0}
    }
  end

  defp do_palette_action(:diff_all_files, state),
    do: %{
      state
      | modal: %{state.modal | type: :none},
        diff: %{state.diff | sidebar_cursor: 0, scroll: 0}
    }

  defp do_palette_action(:new_initiative, state) do
    open_source_picker(%{state | modal: %{state.modal | type: :none}})
  end

  defp do_palette_action(:integrations, state) do
    %{
      state
      | modal: %{
          state.modal
          | type: :service_setup,
            context: :standalone,
            service_setup: %{cursor: 0}
        }
    }
  end

  defp do_palette_action(:add_dir, state),
    do: open_add_dir_modal(%{state | modal: %{state.modal | type: :none}})

  defp do_palette_action(:cycle_status, state),
    do: cycle_initiative_status(%{state | modal: %{state.modal | type: :none}}, :next)

  defp do_palette_action(:delete_current, state),
    do: open_delete_confirm(%{state | modal: %{state.modal | type: :none}})

  defp do_palette_action(:start_claude, state),
    do: start_agent_at_cursor(%{state | modal: %{state.modal | type: :none}}, Claude)

  defp do_palette_action(:start_terminal, state),
    do: start_agent_at_cursor(%{state | modal: %{state.modal | type: :none}}, Terminal)

  defp do_palette_action(:start_aider, state),
    do: start_agent_at_cursor(%{state | modal: %{state.modal | type: :none}}, Aider)

  defp do_palette_action(:new_context_file, state),
    do: open_new_context_file_modal(%{state | modal: %{state.modal | type: :none}})

  defp do_palette_action(:edit_context_file, state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:context_file, _, path, _} ->
        start_editing(%{state | modal: %{state.modal | type: :none}}, path)

      _ ->
        flash_status(
          %{state | modal: %{state.modal | type: :none}},
          "Navigate to a context file first"
        )
    end
  end

  defp do_palette_action(:theme_picker, state) do
    themes = theme_picker_list()
    cursor = Enum.find_index(themes, fn %{theme: t} -> t.name == state.theme.name end) || 0

    %{
      state
      | modal: %{
          state.modal
          | type: :theme_picker,
            theme_picker: %{cursor: cursor, before: state.theme}
        }
    }
  end

  defp do_palette_action(:toggle_dir_worktree, state),
    do: toggle_dir_worktree_at_cursor(%{state | modal: %{state.modal | type: :none}})

  defp do_palette_action(:toggle_worktree_default, state),
    do: toggle_worktree_default(%{state | modal: %{state.modal | type: :none}})

  defp do_palette_action(:refresh, state),
    do: refresh_current(%{state | modal: %{state.modal | type: :none}})

  defp sync_modal(state, :palette) do
    filter = ExRatatui.text_input_get_value(state.modal.input)
    %{state | modal: %{state.modal | palette: %{filter: filter, cursor: 0}}}
  end

  defp sync_modal(state, :new_dir), do: state |> DirPicker.sync() |> refresh_worktree_git()

  defp sync_modal(state, _), do: state

  defp refresh_worktree_git(state) do
    typed =
      state.modal.input |> ExRatatui.text_input_get_value() |> String.trim() |> Path.expand()

    is_git = File.dir?(typed) and Worktree.git_repo?(typed)
    was_git = state.modal.worktree_git

    new_enabled =
      cond do
        is_git and not was_git -> true
        not is_git -> false
        true -> state.modal.worktree_enabled
      end

    %{state | modal: %{state.modal | worktree_git: is_git, worktree_enabled: new_enabled}}
  end

  defp navigate(state, delta) do
    if Focus.focused?(state.focus, :sidebar) do
      if state.active_tab == :diff do
        # In diff mode the sidebar shows diff entries; navigate those independently.
        max_idx = max(length(state.diff.sidebar_entries) - 1, 0)
        new_cursor = min(max(state.diff.sidebar_cursor + delta, 0), max_idx)
        %{state | diff: %{state.diff | sidebar_cursor: new_cursor, scroll: 0}}
      else
        max_idx = max(length(state.sidebar.entries) - 1, 0)
        new_cursor = min(max(state.sidebar.cursor + delta, 0), max_idx)

        %{state | sidebar: %{state.sidebar | cursor: new_cursor}, main_scroll: 0}
        |> update_context_from_cursor()
      end
    else
      case state.active_tab do
        :diff -> %{state | diff: %{state.diff | scroll: max(state.diff.scroll + delta * 3, 0)}}
        _ -> %{state | main_scroll: max(state.main_scroll + delta * 3, 0)}
      end
    end
  end

  defp update_context_from_cursor(state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:initiative, id, _, _, _, _} ->
        fetch_initiative_context(state, id)

      {:dir, initiative_id, dir, _, _} ->
        fetch_dir_context(state, initiative_id, dir)

      {:context_dir, initiative_id, path, _} ->
        fetch_context_dir_context(state, initiative_id, path)

      {:context_file, initiative_id, path, _name} ->
        fetch_context_file(state, initiative_id, path)

      {:agent, agent_id, _, _} ->
        maybe_subscribe_agent(state, agent_id)

      nil ->
        state
    end
  end

  defp fetch_initiative_context(state, initiative_id) do
    case Store.get(initiative_id) do
      {:ok, initiative} ->
        agents = Enum.map(AgentSupervisor.list_agents(), &AgentProcess.status/1)
        by_dir = Enum.group_by(agents, & &1.dir)

        dir_infos =
          Enum.map(initiative.dirs, fn entry ->
            effective = DirEntry.effective_path(entry)

            %{
              path: entry.path,
              branch: git_output(effective, ["branch", "--show-current"]),
              last_commit: git_output(effective, ["log", "-1", "--format=%h %s"]),
              agent_count: length(Map.get(by_dir, effective, [])),
              worktree_enabled: entry.worktree_enabled,
              worktree_path: entry.worktree_path
            }
          end)

        context_dir = Store.context_path(initiative_id)
        context_files = list_context_files(context_dir)

        md_sections =
          context_dir
          |> Path.join("initiative.md")
          |> File.read()
          |> case do
            {:ok, text} -> parse_initiative_sections(text)
            {:error, _} -> []
          end

        cursor_info = %{
          type: :initiative,
          name: initiative.name,
          id: initiative.id,
          status: initiative.status || :ongoing,
          context_dir: context_dir,
          context_files: context_files,
          dirs: dir_infos,
          md_sections: md_sections,
          worktree_default: initiative.worktree_default
        }

        %{
          state
          | cursor_info: cursor_info,
            selection: %{state.selection | initiative_id: initiative_id}
        }

      {:error, :not_found} ->
        state
    end
  end

  defp list_context_files(path) do
    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.reject(fn f ->
          String.starts_with?(f, ".") or File.dir?(Path.join(path, f))
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp fetch_context_dir_context(state, initiative_id, path) do
    files = list_context_files(path)

    cursor_info = %{
      type: :context_dir,
      path: path,
      files: files
    }

    %{
      state
      | cursor_info: cursor_info,
        selection: %{state.selection | initiative_id: initiative_id}
    }
  end

  defp fetch_context_file(state, initiative_id, path) do
    content =
      case File.read(path) do
        {:ok, text} -> text
        {:error, reason} -> "(could not read file: #{inspect(reason)})"
      end

    cursor_info = %{type: :context_file, path: path, content: content}

    %{
      state
      | cursor_info: cursor_info,
        selection: %{state.selection | initiative_id: initiative_id}
    }
  end

  defp fetch_dir_context(state, initiative_id, dir) do
    entry =
      case Store.get(initiative_id) do
        {:ok, initiative} -> Enum.find(initiative.dirs, &(&1.path == dir))
        _ -> nil
      end

    effective = if entry, do: DirEntry.effective_path(entry), else: dir

    branch = git_output(effective, ["branch", "--show-current"])
    remote = git_output(effective, ["remote", "get-url", "origin"])
    commits_raw = git_output(effective, ["log", "--oneline", "-5"])
    commits = String.split(commits_raw, "\n", trim: true)

    source_branch =
      if entry && entry.worktree_path,
        do: git_output(dir, ["branch", "--show-current"])

    cursor_info = %{
      type: :dir,
      path: dir,
      branch: branch,
      remote: remote,
      commits: commits,
      worktree_path: entry && entry.worktree_path,
      source_branch: source_branch
    }

    %{
      state
      | cursor_info: cursor_info,
        selection: %{state.selection | initiative_id: initiative_id}
    }
  end

  defp maybe_subscribe_agent(state, agent_id) do
    if MapSet.member?(state.agents.subscribed, agent_id) do
      # Already receiving live updates — switch display without re-subscribing.
      # Send a deferred SIGWINCH so Claude Code repaints at the current pane size,
      # which corrects any scroll drift without rebuilding the VT100 from scratch.
      # Skip the nudge for Terminal agents — the two-step resize is Ink-specific
      # and would just cause the shell to print a spurious extra prompt.
      status = lookup_agent_status(state, agent_id)

      %{
        state
        | selection: %{state.selection | agent_id: agent_id, agent_mode: status},
          main_scroll: 0
      }
    else
      subscribe_to_agent(state, agent_id)
    end
  end

  defp subscribe_to_agent(state, agent_id) do
    case AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} ->
        try do
          AgentProcess.subscribe(pid)
          status = AgentProcess.status(pid)
          {w, h} = state.pane_size
          existing = pid |> AgentProcess.recent_output(200) |> Enum.reverse()

          # Claude Code (Ink): only replay from last \e[2J anchor — IL/DL need scroll-region context.
          # Terminal/shell: replay all output — shells never send \e[2J to draw their prompt.
          replay =
            if status.adapter == Claude, do: chunks_from_last_clear(existing), else: existing

          new_refs = setup_agent_refs(state, pid, agent_id, replay, status.adapter, {w, h})

          screen =
            Enum.reduce(replay, VT100.new(w, h), fn chunk, s -> VT100.process(s, chunk) end)

          short = String.slice(agent_id, 0, 8)

          %{
            state
            | refs: new_refs,
              selection: %{state.selection | agent_id: agent_id, agent_mode: status.mode},
              agents: %{
                state.agents
                | subscribed: MapSet.put(state.agents.subscribed, agent_id),
                  outputs: Map.put(state.agents.outputs, agent_id, existing),
                  screens: Map.put(state.agents.screens, agent_id, screen)
              },
              main_scroll: agent_initial_scroll(status.adapter, screen),
              status: "Subscribed to #{short} — Tab to focus, then type"
          }
        catch
          :exit, _ ->
            flash_status(state, "Agent #{agent_id} not responding")
        end

      {:error, :not_found} ->
        flash_status(state, "Agent #{agent_id} not found")
    end
  end

  # Claude Code (Ink renderer): two-step resize forces a full \e[2J repaint.
  # A nudge fires at 600 ms only when there's no existing output (slow-starting agents).
  # Cancel stale timers from any previous subscription first.
  # Terminal/shell agents: a single resize suffices — two-step causes extra shell prompts.
  defp setup_agent_refs(state, pid, agent_id, replay, Claude, {w, h}) do
    if state.refs.nudge, do: Process.cancel_timer(state.refs.nudge)
    if state.refs.restore, do: Process.cancel_timer(state.refs.restore)
    AgentProcess.resize(pid, max(w - 1, 1), h)
    restore_ref = Process.send_after(self(), {:restore_agent_size, agent_id, w, h}, 150)

    nudge_ref =
      if Enum.empty?(replay), do: Process.send_after(self(), {:nudge_agent, agent_id, w, h}, 600)

    %{state.refs | nudge: nudge_ref, restore: restore_ref}
  end

  defp setup_agent_refs(state, pid, _agent_id, _replay, _adapter, {w, h}) do
    AgentProcess.resize(pid, w, h)
    state.refs
  end

  # For Terminal agents, zsh/starship emit \n before each prompt, leaving row 0 blank on replay.
  defp agent_initial_scroll(Claude, _screen), do: 0
  defp agent_initial_scroll(_adapter, screen), do: VT100.first_content_row(screen)

  defp start_agent_at_cursor(state, adapter) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:initiative, id, _, _, _, _} ->
        do_start_agent(state, id, Store.context_path(id), adapter)

      {:dir, initiative_id, source_path, _, _} ->
        do_start_agent(state, initiative_id, resolve_dir(initiative_id, source_path), adapter)

      {:context_dir, initiative_id, path, _} ->
        do_start_agent(state, initiative_id, path, adapter)

      {:context_file, initiative_id, file_path, _} ->
        do_start_agent(state, initiative_id, Path.dirname(file_path), adapter)

      _ ->
        flash_status(state, "Navigate to an initiative or directory to start an agent")
    end
  end

  defp resolve_dir(initiative_id, source_path) do
    case Store.get(initiative_id) do
      {:ok, initiative} ->
        entry = Enum.find(initiative.dirs, &(&1.path == source_path))
        if entry, do: DirEntry.effective_path(entry), else: source_path

      _ ->
        source_path
    end
  end

  defp do_start_agent(state, initiative_id, dir, adapter, agent_id \\ nil) do
    tui = self()
    {cols, rows} = state.pane_size
    opts = if agent_id, do: [id: agent_id], else: []

    Task.Supervisor.start_child(Codrift.TaskSupervisor, fn ->
      case AgentSupervisor.start_agent(initiative_id, dir, adapter, opts) do
        {:ok, pid} ->
          AgentProcess.resize(pid, cols, rows)
          send(tui, {:agent_started, dir})

        {:error, reason} ->
          send(tui, {:agent_start_failed, reason})
      end
    end)

    %{state | status: "Starting agent in #{Paths.compact(dir)}..."}
  end

  defp toggle_dir_worktree_at_cursor(state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:dir, initiative_id, source_path, _, _} ->
        case Store.toggle_dir_worktree(initiative_id, source_path) do
          {:ok, _} ->
            state
            |> reload_sidebar()
            |> refresh_current()
            |> flash_status("Worktree toggled for #{Paths.compact(source_path)}")

          {:error, reason} ->
            flash_status(state, "Worktree toggle failed: #{inspect(reason)}")
        end

      _ ->
        flash_status(state, "Navigate to a directory entry to toggle its worktree")
    end
  end

  defp toggle_worktree_default(state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {type, initiative_id, _, _, _, _} when type in [:initiative] ->
        do_toggle_worktree_default(state, initiative_id)

      {type, initiative_id, _, _} when type in [:dir, :context_dir] ->
        do_toggle_worktree_default(state, initiative_id)

      _ ->
        flash_status(state, "Navigate to an initiative or directory first")
    end
  end

  defp do_toggle_worktree_default(state, initiative_id) do
    case Store.get(initiative_id) do
      {:ok, initiative} ->
        new_default = not initiative.worktree_default

        case Store.set_worktree_default(initiative_id, new_default) do
          {:ok, _} ->
            label = if new_default, do: "ON", else: "OFF"
            flash_status(state, "Worktree default #{label} for this initiative")

          {:error, reason} ->
            flash_status(state, "Failed: #{inspect(reason)}")
        end

      _ ->
        state
    end
  end

  defp cycle_initiative_status(state, direction) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:initiative, id, _, _, _, current_status} ->
        new_status =
          case direction do
            :next -> Initiative.next_status(current_status)
            :prev -> Initiative.prev_status(current_status)
          end

        case Store.set_status(id, new_status) do
          {:ok, _} ->
            state
            |> reload_sidebar()
            |> update_context_from_cursor()
            |> then(&flash_status(&1, "Status → #{new_status}"))

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp open_new_context_file_modal(state) do
    ctx_dir =
      case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
        {:initiative, id, _, _, _, _} ->
          Store.context_path(id)

        {:context_dir, _, path, _} ->
          path

        {:context_file, _, file_path, _} ->
          Path.dirname(file_path)

        _ ->
          if state.selection.initiative_id, do: Store.context_path(state.selection.initiative_id)
      end

    if is_nil(ctx_dir) do
      flash_status(state, "Navigate to an initiative first")
    else
      ExRatatui.text_input_set_value(state.modal.input, "")

      %{
        state
        | modal: %{state.modal | type: :new_context_file, context: {:new_context_file, ctx_dir}},
          status: "Enter filename — Enter: create  Esc: cancel"
      }
    end
  end

  defp confirm_context_file(%{modal: %{context: {:new_context_file, ctx_dir}}} = state) do
    filename = state.modal.input |> ExRatatui.text_input_get_value() |> String.trim()

    cond do
      filename == "" ->
        flash_status(state, "Filename cannot be empty")

      String.contains?(filename, "/") or String.contains?(filename, "..") ->
        flash_status(state, "Filename must not contain '/' or '..'")

      true ->
        path = Path.join(ctx_dir, filename)

        with true <- Store.context_file_path?(path),
             :ok <- File.write(path, "") do
          state
          |> reload_sidebar()
          |> update_context_from_cursor()
          |> then(
            &flash_status(
              %{&1 | modal: %{&1.modal | type: :none, context: nil}},
              "Created #{filename}"
            )
          )
        else
          false ->
            flash_status(
              %{state | modal: %{state.modal | type: :none, context: nil}},
              "Refused: path outside Codrift context folder"
            )

          {:error, reason} ->
            flash_status(
              %{state | modal: %{state.modal | type: :none, context: nil}},
              "Failed: #{inspect(reason)}"
            )
        end
    end
  end

  defp confirm_context_file(state),
    do: %{state | modal: %{state.modal | type: :none, context: nil}}

  defp refresh_current(%{active_tab: :diff} = state), do: refresh_diff(state)

  defp refresh_current(state) do
    state |> reload_sidebar() |> update_context_from_cursor()
  end

  defp refresh_diff(%{selection: %{initiative_id: nil}} = state) do
    flash_status(state, "Select an initiative first")
  end

  defp refresh_diff(state) do
    case Store.get(state.selection.initiative_id) do
      {:ok, initiative} ->
        dir_diffs =
          Enum.map(initiative.dirs, fn entry ->
            {entry.path, diff_for_dir(DirEntry.effective_path(entry))}
          end)

        total_files = Enum.sum(Enum.map(dir_diffs, fn {_, fs} -> length(fs) end))
        diff_sidebar = Sidebar.build_diff_entries(dir_diffs)

        flash_status(
          %{
            state
            | diff: %{
                state.diff
                | files: dir_diffs,
                  sidebar_entries: diff_sidebar,
                  sidebar_cursor: 0,
                  scroll: 0
              }
          },
          "Diff: #{total_files} file(s) changed"
        )

      {:error, :not_found} ->
        flash_status(state, "Initiative not found")
    end
  end

  defp diff_for_dir(dir) do
    case Diff.generate(dir) do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end

  defp git_output(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "(not a git repo)"
    end
  end

  defp reload_sidebar(state) do
    initiatives = Store.list()

    agents =
      AgentSupervisor.list_agents()
      |> Enum.flat_map(fn pid ->
        try do
          [AgentProcess.status(pid)]
        catch
          :exit, _ -> []
        end
      end)

    %{state | sidebar: %{state.sidebar | entries: Sidebar.build_entries(initiatives, agents)}}
  end

  defp render_mode_bar(state) do
    {context_style, diff_style} =
      case state.active_tab do
        :context ->
          {%Style{fg: :yellow, modifiers: [:bold]}, %Style{fg: :dark_gray}}

        :diff ->
          {%Style{fg: :dark_gray}, %Style{fg: :yellow, modifiers: [:bold]}}
      end

    alias ExRatatui.Text.{Line, Span}

    %ExRatatui.Widgets.Paragraph{
      text: %ExRatatui.Text{
        lines: [
          %Line{
            spans: [
              %Span{content: " 1: Context ", style: context_style},
              %Span{content: " │ ", style: %Style{fg: :dark_gray}},
              %Span{content: "2: Diff ", style: diff_style}
            ]
          }
        ]
      }
    }
  end

  defp render_main(%{active_tab: :context} = state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:initiative, _, name, _, _, _} -> render_initiative_pane(state, name)
      {:dir, _, dir, _, _} -> render_dir_pane(state, dir)
      {:context_dir, _, path, _} -> render_context_dir_pane(state, path)
      {:context_file, _, _, _} -> render_context_file_pane(state)
      {:agent, id, adapter, status} -> render_agent_pane(state, id, adapter, status)
      nil -> render_placeholder(state)
    end
  end

  defp render_initiative_pane(state, name) do
    case state.cursor_info do
      %{
        type: :initiative,
        status: status,
        context_dir: ctx_dir,
        context_files: files,
        dirs: dirs,
        md_sections: md_sections,
        worktree_default: wt_default
      } ->
        content = build_initiative_md_content(md_sections, dirs, files, ctx_dir, wt_default)

        %CodeBlock{
          content: content,
          language: "md",
          theme: state.theme.syntax_theme,
          line_numbers: false,
          block: %Block{
            title: " #{name} · #{status} ",
            borders: [:all],
            border_type: :rounded,
            border_style: Styles.pane_border(state.focus, :main, state.theme)
          },
          scroll: {state.main_scroll, 0}
        }

      %{
        type: :initiative,
        status: status,
        context_dir: ctx_dir,
        context_files: files,
        dirs: dirs
      } ->
        # fallback when md_sections not yet populated
        content = build_initiative_md_content([], dirs, files, ctx_dir, false)

        %CodeBlock{
          content: content,
          language: "md",
          theme: state.theme.syntax_theme,
          line_numbers: false,
          block: %Block{
            title: " #{name} · #{status} ",
            borders: [:all],
            border_type: :rounded,
            border_style: Styles.pane_border(state.focus, :main, state.theme)
          },
          scroll: {state.main_scroll, 0}
        }

      _ ->
        %Paragraph{
          text: "Loading…",
          block: %Block{
            title: " #{name} ",
            borders: [:all],
            border_type: :rounded,
            border_style: Styles.pane_border(state.focus, :main, state.theme)
          }
        }
    end
  end

  defp render_context_dir_pane(state, path) do
    text =
      case state.cursor_info do
        %{type: :context_dir, files: []} ->
          "No files yet.\n\nPress 'c' to add a file or drop one here.\n\n◈ #{Paths.compact(path)}"

        %{type: :context_dir, files: files} ->
          file_list = Enum.map_join(files, "\n", fn f -> "  #{f}" end)

          "◈ #{Paths.compact(path)}\n\n#{file_list}\n\nPress 'c' to create · 's' to start Claude · 't' for a terminal"

        _ ->
          "Loading…"
      end

    %Paragraph{
      text: text,
      block: %Block{
        title: " ◈ context ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(state.focus, :main, state.theme)
      },
      wrap: true,
      scroll: {state.main_scroll, 0}
    }
  end

  defp render_context_file_pane(state) do
    case state.cursor_info do
      %{type: :context_file, path: path, content: content} ->
        render_file_widget(state, path, content)

      _ ->
        %Paragraph{
          text: "Loading…",
          block: %Block{
            title: "  ",
            borders: [:all],
            border_type: :rounded,
            border_style: Styles.pane_border(state.focus, :main, state.theme)
          }
        }
    end
  end

  defp render_file_widget(%{editor: %{file: path}} = state, path, _content) do
    %Textarea{
      state: state.editor.ref,
      style: %Style{fg: :white},
      cursor_style: %Style{modifiers: [:reversed]},
      cursor_line_style: %Style{bg: :dark_gray},
      line_number_style: %Style{fg: :dark_gray},
      block: %Block{
        title: " ~ #{Path.basename(path)}  Esc: save & close  autosaves ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :yellow}
      }
    }
  end

  defp render_file_widget(state, path, content) do
    display = if content == "", do: "(empty file — press e to edit)", else: content

    %CodeBlock{
      content: display,
      language: detect_language(path),
      theme: state.theme.syntax_theme,
      line_numbers: true,
      block: %Block{
        title: " #{Path.basename(path)}  e: edit  d: delete ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(state.focus, :main, state.theme)
      },
      scroll: {state.main_scroll, 0}
    }
  end

  defp render_dir_pane(state, dir) do
    text =
      case state.cursor_info do
        %{type: :dir, branch: branch, remote: remote, commits: commits} = info ->
          remote_line = if remote == "(not a git repo)", do: "", else: "Remote:   #{remote}\n"
          commits_text = Enum.map_join(commits, "\n", fn c -> "  #{c}" end)

          worktree_section =
            case info do
              %{worktree_path: wt, source_branch: src} when is_binary(wt) ->
                "Worktree: #{Paths.compact(wt)}\nSrc branch: #{src || "?"}  (#{Paths.compact(dir)})\n"

              _ ->
                "Worktree: none  (W to enable)\n"
            end

          "Path:     #{Paths.compact(dir)}\nBranch:   #{branch}\n#{worktree_section}#{remote_line}\nRecent commits:\n#{commits_text}"

        _ ->
          "Loading…"
      end

    %Paragraph{
      text: text,
      block: %Block{
        title: " ▸ #{Path.basename(dir)} ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(state.focus, :main, state.theme)
      },
      wrap: true,
      scroll: {state.main_scroll, 0}
    }
  end

  defp render_agent_pane(state, agent_id, adapter, status) do
    focused = Focus.focused?(state.focus, :main)
    title = " #{Codrift.Agent.adapter_name(adapter)} (#{Styles.format_status(status)}) "
    border = Styles.pane_border(state.focus, :main, state.theme)
    block = %Block{title: title, borders: [:all], border_type: :rounded, border_style: border}

    screen = Map.get(state.agents.screens, agent_id)
    raw_output = Map.get(state.agents.outputs, agent_id, [])
    has_output = screen != nil and (map_size(screen.cells) > 0 or raw_output != [])

    if has_output do
      render_agent_output(state, screen, focused, block)
    else
      render_agent_hint(status, focused, state.paste_mode, block)
    end
  end

  defp render_agent_hint(status, focused, paste_mode, block) do
    %Paragraph{text: agent_hint(status, focused, paste_mode), block: block, wrap: true}
  end

  defp agent_hint(:stopped, _focused, _paste_mode), do: "Agent stopped. Press s to restart."

  defp agent_hint(:starting, _focused, _paste_mode),
    do: "Starting… waiting for the agent prompt to appear."

  defp agent_hint(_status, true, true),
    do: "PASTE MODE — Enter inserts newline · Ctrl+V to exit · Enter to send after"

  defp agent_hint(:awaiting_input, true, _paste_mode),
    do: "Agent ready. Type your message. Ctrl+V for paste mode, Enter to send."

  defp agent_hint(:awaiting_input, _focused, _paste_mode),
    do: "Agent ready. Tab to focus, then type your message."

  defp agent_hint(:running, _focused, _paste_mode), do: "Agent is working…"

  defp agent_hint(_status, true, _paste_mode),
    do: "Shift+Tab to sidebar · Ctrl+V paste mode · Enter to send"

  defp agent_hint(_status, _focused, _paste_mode),
    do: "Navigate here then Tab to focus. Type to interact."

  defp render_agent_output(state, screen, focused, block) do
    prompt_suffix =
      if focused and state.selection.agent_mode != :pty and state.input_buffer != "",
        do: "\n> #{state.input_buffer}▌",
        else: ""

    content =
      if prompt_suffix == "",
        do: VT100.to_text(screen, focused),
        else: append_prompt(VT100.to_text(screen, false), prompt_suffix)

    %Paragraph{text: content, block: block, wrap: false, scroll: {state.main_scroll, 0}}
  end

  defp append_prompt(%ExRatatui.Text{lines: lines} = text, suffix) do
    alias ExRatatui.Text.{Line, Span}

    extra =
      suffix
      |> String.split("\n")
      |> Enum.map(fn line ->
        %Line{spans: [%Span{content: line}]}
      end)

    %{text | lines: lines ++ extra}
  end

  defp resize_selected_pty(nil, _w, _h), do: :ok

  defp resize_selected_pty(agent_id, w, h) do
    case AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} -> AgentProcess.resize(pid, w, h)
      _ -> :ok
    end
  end

  defp render_main_area(%{active_tab: :diff} = state, rect) do
    render_diff_content(state, rect)
  end

  defp render_main_area(state, rect) do
    [{render_main(state), rect}]
  end

  # ── Diff content pane ────────────────────────────────────────────────────────
  # Driven by the diff sidebar cursor — no separate file-list panel.

  defp render_diff_content(state, rect) do
    files = diff_files_for_cursor(state)
    title = diff_content_title(state)
    # In diff mode the content pane is always the primary reading surface, so
    # always show it with an active border regardless of which pane has focus.
    border = Styles.diff_border(state.theme)

    case state.diff.view_mode do
      :unified ->
        content =
          if files == [],
            do: "No changes in this directory.",
            else: Enum.map_join(files, "\n", &Diff.to_unified/1)

        [
          {%CodeBlock{
             content: content,
             language: "diff",
             theme: state.theme.syntax_theme,
             line_numbers: false,
             block: %Block{
               title: title,
               borders: [:all],
               border_type: :rounded,
               border_style: border
             },
             scroll: {state.diff.scroll, 0}
           }, rect}
        ]

      :split ->
        [left_rect, right_rect] =
          Layout.split(rect, :horizontal, [{:percentage, 50}, {:percentage, 50}])

        rows = Enum.flat_map(files, &Diff.to_split_rows/1)
        left_text = build_split_text(rows, :old)
        right_text = build_split_text(rows, :new)

        left_block = %Block{
          title: " - removed ",
          borders: [:all],
          border_type: :rounded,
          border_style: %Style{fg: :red}
        }

        right_block = %Block{
          title: " + added ",
          borders: [:all],
          border_type: :rounded,
          border_style: %Style{fg: :green}
        }

        [
          {%Paragraph{
             text: left_text,
             block: left_block,
             wrap: false,
             scroll: {state.diff.scroll, 0}
           }, left_rect},
          {%Paragraph{
             text: right_text,
             block: right_block,
             wrap: false,
             scroll: {state.diff.scroll, 0}
           }, right_rect}
        ]
    end
  end

  # Builds a %ExRatatui.Text{} for one side of the split diff view.
  # Removes are red on the old side, adds are green on the new side.
  # Padding rows (nil) render as empty lines with a faint background marker.
  defp build_split_text(rows, side) do
    lines = Enum.map(rows, &build_split_line(&1, side))
    %ExRatatui.Text{lines: lines}
  end

  defp build_split_line({:header, old, new}, side) do
    alias ExRatatui.Text.{Line, Span}
    content = if side == :old, do: old || "", else: new || ""
    %Line{spans: [%Span{content: content, style: %Style{fg: :dark_gray}}]}
  end

  defp build_split_line({:context, old, new}, side) do
    alias ExRatatui.Text.{Line, Span}
    content = if side == :old, do: old || "", else: new || ""
    %Line{spans: [%Span{content: content}]}
  end

  defp build_split_line({:change, old, _new}, :old) do
    alias ExRatatui.Text.{Line, Span}
    content = old || "~"
    style = if old, do: %Style{fg: :red}, else: %Style{fg: :dark_gray}
    %Line{spans: [%Span{content: content, style: style}]}
  end

  defp build_split_line({:change, _old, new}, :new) do
    alias ExRatatui.Text.{Line, Span}
    content = new || "~"
    style = if new, do: %Style{fg: :green}, else: %Style{fg: :dark_gray}
    %Line{spans: [%Span{content: content, style: style}]}
  end

  # Returns the subset of FileDiff structs to display based on the diff
  # sidebar cursor position.
  defp diff_files_for_cursor(%{diff: %{sidebar_entries: [], files: dir_diffs}}) do
    Enum.flat_map(dir_diffs, fn {_, files} -> files end)
  end

  defp diff_files_for_cursor(%{
         diff: %{sidebar_entries: entries, sidebar_cursor: cursor, files: dir_diffs}
       }) do
    all_files = Enum.flat_map(dir_diffs, fn {_, files} -> files end)

    case Enum.at(entries, cursor) do
      {:diff_all, _, _} ->
        all_files

      {:diff_dir, dir, _, _} ->
        dir_diffs
        |> Enum.find({nil, []}, fn {d, _} -> d == dir end)
        |> elem(1)

      {:diff_file, _dir, path, _, _} ->
        Enum.filter(all_files, &(&1.path == path))

      nil ->
        all_files
    end
  end

  # Builds the title string for the diff content pane from the active sidebar entry.
  defp diff_content_title(state) do
    entry = Enum.at(state.diff.sidebar_entries, state.diff.sidebar_cursor)
    mode_hint = " v:#{next_view_mode(state.diff.view_mode)} *:all "

    case entry do
      {:diff_all, _, _} -> " Diff #{mode_hint}"
      {:diff_dir, dir, _, _} -> " ▸ #{Paths.compact(dir)} #{mode_hint}"
      {:diff_file, _, path, _, _} -> " #{Path.basename(path)} #{mode_hint}"
      nil -> " Diff "
    end
  end

  defp next_view_mode(:unified), do: "split"
  defp next_view_mode(:split), do: "unified"

  # Scroll whichever pane the mouse cursor is over.
  # If the pointer is in the sidebar column, scroll the sidebar (navigate).
  # If it's in the main pane and the agent is a PTY, forward scroll as
  # arrow keys so the shell/Claude gets the scroll event natively.
  # Otherwise adjust main_scroll for code-viewer / initiative panes.
  defp mouse_scroll(state, %Mouse{x: x}, delta) do
    {term_w, _} = state.term_size || {80, 24}
    sidebar_width = if state.sidebar.collapsed, do: 0, else: round(term_w * 0.30)

    cond do
      x < sidebar_width ->
        # Scrolling over the sidebar navigates its cursor
        new_cursor =
          (state.sidebar.cursor + delta)
          |> max(0)
          |> min(max(length(state.sidebar.entries) - 1, 0))

        %{state | sidebar: %{state.sidebar | cursor: new_cursor}}
        |> update_context_from_cursor()

      state.selection.agent_mode == :pty ->
        # PTY agents: forward scroll as arrow-key sequences (3 lines per tick)
        seq = if delta < 0, do: "\e[A", else: "\e[B"
        Enum.reduce(1..abs(delta), state, fn _, s -> forward_raw(s, seq) end)

      true ->
        # Code viewer / initiative / diff panes: move main_scroll
        %{state | main_scroll: max(state.main_scroll + delta, 0)}
    end
  end

  defp forward_raw(state, data) do
    screen = Map.get(state.agents.screens, state.selection.agent_id)

    # Claude Code sends \e[?25l (hide cursor) while repainting and \e[?25h when
    # done. Forwarding keystrokes mid-repaint lands them at cursor_row=0 (the
    # \e[H from the clear), not at the input line. Drop input until the cursor
    # is visible again — repaints complete in < 200 ms so no keys are lost.
    if screen == nil or screen.cursor_visible do
      with id when not is_nil(id) <- state.selection.agent_id,
           {:ok, pid} <- AgentSupervisor.find_agent(id) do
        AgentProcess.send_raw(pid, data)
      end
    end

    state
  end

  defp send_agent_input(state) do
    text = String.trim(state.input_buffer)
    base = %{state | input_buffer: "", paste_mode: false}

    if text == "" or is_nil(state.selection.agent_id) do
      base
    else
      case AgentSupervisor.find_agent(state.selection.agent_id) do
        {:ok, pid} ->
          AgentProcess.send_input(pid, text)

          flash_status(
            base,
            "Sent → #{String.slice(state.selection.agent_id, 0, 8)}"
          )

        {:error, :not_found} ->
          flash_status(base, "Agent not found")
      end
    end
  end

  defp render_placeholder(state) do
    %Paragraph{
      text:
        "Navigate the sidebar with j/k to view initiative info, folder details, or agent output.",
      block: %Block{
        title: " Codrift ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(state.focus, :main, state.theme)
      },
      wrap: true
    }
  end

  defp render_footer(state) do
    %Paragraph{text: state.status, style: %Style{fg: :dark_gray}}
  end

  # Ratatui allocates sidebar first (floor(w * 30/100)), main gets the remainder.
  # Using `w - floor(w*30/100)` matches that exactly; `floor(w*70/100)` diverges
  # by 1 on odd widths, causing Claude Code to draw at the wrong column count.
  defp calc_pane_size(term_w, term_h, sidebar_collapsed \\ false) do
    sidebar_w = if sidebar_collapsed, do: 0, else: div(term_w * 30, 100)
    cols = max(term_w - sidebar_w - 2, 1)
    rows = max(term_h - 4, 1)
    {cols, rows}
  end

  # Find the last full-screen clear anchor in a chunk list and return everything
  # from that chunk onwards.  \e[2J (ED 2) and \ec (RIS) are both "fresh screen"
  # signals — everything after them is a self-contained repaint.
  #
  # Returns [] when no clear is found so the caller starts with an empty VT100
  # screen.  For a just-started agent the clear hasn't arrived yet; the two-step
  # resize will trigger Claude's full \e[2J repaint which will fill the screen.
  defp chunks_from_last_clear(chunks) do
    clear_pattern = :binary.compile_pattern(["\e[2J", "\ec"])

    chunks
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {chunk, idx}, last ->
      if :binary.match(chunk, clear_pattern) != :nomatch, do: idx, else: last
    end)
    |> case do
      nil -> []
      idx -> Enum.drop(chunks, idx)
    end
  end

  # ── Text editor helpers ──────────────────────────────────────────────────────

  defp start_editing(state, path) do
    content =
      case File.read(path) do
        {:ok, text} -> text
        {:error, _} -> ""
      end

    ExRatatui.textarea_set_value(state.editor.ref, content)

    %{
      state
      | editor: %{state.editor | file: path},
        status:
          "editing — Esc: save & close  Ctrl+K: kill line  Ctrl+W: delete word  autosaves every 500 ms"
    }
  end

  # Saves and exits edit mode (Esc). Shows a brief confirmation then restores
  # the default shortcuts hint after 2 s.
  defp save_and_close_editing(state) do
    if state.editor.autosave, do: Process.cancel_timer(state.editor.autosave)
    base = %{state | editor: %{state.editor | file: nil, autosave: nil}}

    if Store.context_file_path?(state.editor.file) do
      content = ExRatatui.textarea_get_value(state.editor.ref)

      case File.write(state.editor.file, content) do
        :ok ->
          base
          |> reload_sidebar()
          |> update_context_from_cursor()
          |> flash_status("Saved #{Path.basename(state.editor.file)}")

        {:error, reason} ->
          flash_status(base, "Save failed: #{inspect(reason)}", 3000)
      end
    else
      flash_status(base, "Refused: path outside Codrift context folder", 3000)
    end
  end

  # ── Initiative context prompt ─────────────────────────────────────────────────

  # Sends the initiative.md content as the first message when a non-Terminal
  # agent becomes ready.  Terminal adapters run a PTY shell — sending text
  # would just echo it, which is not useful.
  defp send_initiative_context_prompt(agent_id) do
    with {:ok, pid} <- AgentSupervisor.find_agent(agent_id),
         status = AgentProcess.status(pid),
         false <- status.adapter == Terminal,
         md_path = Path.join(Store.context_path(status.initiative_id), "initiative.md"),
         {:ok, content} <- File.read(md_path),
         true <- String.trim(content) != "" do
      AgentProcess.send_input(pid, content)
    end

    :ok
  end

  # ── Safety guards ─────────────────────────────────────────────────────────────

  # ── Transient status helper ───────────────────────────────────────────────────

  # Toggles the sidebar collapsed/expanded, resizes VT100 screens and PTYs to
  # match, and shifts focus to the main pane when collapsing a focused sidebar.
  defp toggle_sidebar(state) do
    new_collapsed = not state.sidebar.collapsed
    {term_w, term_h} = state.term_size || {80, 24}
    {pane_w, pane_h} = calc_pane_size(term_w, term_h, new_collapsed)

    new_screens =
      Map.new(state.agents.screens, fn {id, screen} ->
        {id, VT100.resize(screen, pane_w, pane_h)}
      end)

    resize_selected_pty(state.selection.agent_id, pane_w, pane_h)

    new_focus =
      if new_collapsed and Focus.focused?(state.focus, :sidebar),
        do: Focus.new([:main, :sidebar]),
        else: state.focus

    %{
      state
      | sidebar: %{state.sidebar | collapsed: new_collapsed},
        pane_size: {pane_w, pane_h},
        agents: %{state.agents | screens: new_screens},
        focus: new_focus
    }
  end

  # Sets a temporary status message and schedules :reset_status after `ms` ms.
  # Cancels any previously pending reset so rapid calls don't stack timers.
  defp flash_status(state, message, ms \\ 2000) do
    if state.refs.status_timer, do: Process.cancel_timer(state.refs.status_timer)
    ref = Process.send_after(self(), :reset_status, ms)
    %{state | status: message, refs: %{state.refs | status_timer: ref}}
  end

  # `find_syntax_by_token` in syntect resolves tokens against the syntax's
  # file_extensions list, so passing the bare extension (no dot) is the most
  # reliable lookup — "md" finds Markdown, "py" finds Python, "ex" finds
  # Elixir (custom bundled syntax), etc.  Unknown extensions return nil which
  defp lookup_agent_status(state, agent_id) do
    case AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} ->
        agent_status = AgentProcess.status(pid)

        if agent_status.adapter == Claude do
          {w, h} = state.pane_size
          Process.send_after(self(), {:nudge_agent, agent_id, w, h}, 80)
        end

        agent_status.mode

      _ ->
        state.selection.agent_mode
    end
  end

  defp maybe_nudge_agent(agent_id, state) do
    screen = Map.get(state.agents.screens, agent_id)

    with true <- agent_id == state.selection.agent_id,
         true <- screen != nil and screen.cursor_visible,
         {:ok, pid} <- AgentSupervisor.find_agent(agent_id),
         %{status: :awaiting_input, adapter: Claude} <- AgentProcess.status(pid) do
      AgentProcess.send_raw(pid, "\r")
    end
  end

  defp detect_language(path) do
    case Path.extname(path) do
      "" -> nil
      ext -> String.trim_leading(ext, ".")
    end
  end

  # ── initiative.md section parser ─────────────────────────────────────────────

  # Strips the managed dirs block and the title, then extracts each ## section
  # that has non-placeholder content.  Returns [{title, body}] pairs.
  defp parse_initiative_sections(content) do
    without_managed =
      Regex.replace(
        ~r/<!-- codrift:dirs:start -->.*?<!-- codrift:dirs:end -->\n?/s,
        content,
        ""
      )

    without_title = Regex.replace(~r/\A# [^\n]+\n+/s, without_managed, "")

    Regex.scan(
      ~r/^## ([^\n]+)\n(.*?)(?=^## |\z)/ms,
      without_title,
      capture: :all_but_first
    )
    |> Enum.flat_map(fn [title, body] ->
      trimmed = String.trim(body)

      if trimmed == "" or Regex.match?(~r/\A<!--.*-->\z/s, trimmed) do
        []
      else
        [{String.trim(title), trimmed}]
      end
    end)
  end

  # Builds the full markdown content shown in the initiative summary pane.
  defp build_initiative_md_content(md_sections, dirs, files, ctx_dir, worktree_default) do
    user_sections =
      Enum.map_join(md_sections, "\n\n", fn {title, body} -> "## #{title}\n\n#{body}" end)

    wt_tag = if worktree_default, do: "on", else: "off"

    dirs_section =
      if dirs == [] do
        "## Directories\n\n_(no directories added yet — press `a` to add one)_\n\nWorktree default: `#{wt_tag}` _(Ctrl+P → Toggle Worktree Default)_"
      else
        dir_lines = Enum.map_join(dirs, "\n\n", &format_dir_info_md/1)
        "## Directories  _(worktree default: #{wt_tag})_\n\n#{dir_lines}"
      end

    files_section =
      if files == [] do
        "## Context Files\n\n_(empty — drop files into `#{Paths.compact(ctx_dir)}`)_"
      else
        file_lines = Enum.map_join(files, "\n", fn f -> "- #{f}" end)
        "## Context Files\n\n#{file_lines}"
      end

    [user_sections, dirs_section, files_section]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp format_dir_info_md(%{
         path: path,
         branch: branch,
         last_commit: commit,
         agent_count: count,
         worktree_enabled: worktree_enabled,
         worktree_path: worktree_path
       }) do
    agents_label = if count == 0, do: "none", else: "#{count} running"

    worktree_label =
      if worktree_enabled and is_binary(worktree_path),
        do: "worktree: `#{Paths.compact(worktree_path)}`",
        else: "worktree: off  _(W to enable)_"

    "**#{Paths.compact(path)}**  \nbranch: `#{branch}` · #{worktree_label} · commit: `#{commit}` · agents: #{agents_label}"
  end

  # ── Config helpers ────────────────────────────────────────────────────────────

  # Builds the footer status hint string using the active keybindings.
  defp build_default_status(kb) do
    f = &Keybindings.format/1

    "#{f.(kb.navigate_down)}/#{f.(kb.navigate_up)}:navigate  " <>
      "#{f.(kb.new_initiative)}:new  " <>
      "#{f.(kb.start_agent)}:start  " <>
      "#{f.(kb.delete)}:delete  " <>
      "#{f.(kb.start_terminal)}:terminal  " <>
      "Tab:agent pane  " <>
      "#{f.(kb.diff_mode)}:diff  " <>
      "#{f.(kb.palette)}:palette  " <>
      "#{f.(kb.quit)}:quit"
  end

  # Builds the command palette actions list with hints from the active keybindings.
  defp build_actions(kb) do
    [
      # Navigation
      %{
        id: :toggle_sidebar,
        label: "Toggle Sidebar",
        hint: Keybindings.format(kb.toggle_sidebar)
      },
      %{id: :context_mode, label: "Context View", hint: Keybindings.format(kb.context_mode)},
      %{id: :diff_mode, label: "Diff View", hint: Keybindings.format(kb.diff_mode)},
      %{
        id: :toggle_diff_view,
        label: "Toggle Diff: Unified / Split",
        hint: Keybindings.format(kb.toggle_diff_view)
      },
      %{
        id: :diff_all_files,
        label: "Diff: Show All Files",
        hint: Keybindings.format(kb.diff_all_files)
      },
      # Initiatives & directories
      %{
        id: :new_initiative,
        label: "New Initiative",
        hint: Keybindings.format(kb.new_initiative)
      },
      %{id: :add_dir, label: "Add Directory", hint: Keybindings.format(kb.add_dir)},
      %{
        id: :cycle_status,
        label: "Cycle Initiative Status",
        hint: "#{Keybindings.format(kb.status_prev)}/#{Keybindings.format(kb.status_next)}"
      },
      %{id: :toggle_worktree_default, label: "Toggle Worktree Default (initiative)", hint: ""},
      %{id: :toggle_dir_worktree, label: "Toggle Worktree for Directory", hint: "W"},
      %{id: :delete_current, label: "Delete / Stop Current", hint: Keybindings.format(kb.delete)},
      # Agents
      %{id: :start_claude, label: "Start Claude Agent", hint: Keybindings.format(kb.start_agent)},
      %{
        id: :start_terminal,
        label: "Open Terminal Here",
        hint: Keybindings.format(kb.start_terminal)
      },
      %{id: :start_aider, label: "Start Aider Agent", hint: ""},
      # Context files
      %{
        id: :new_context_file,
        label: "New Context File",
        hint: Keybindings.format(kb.new_context)
      },
      %{
        id: :edit_context_file,
        label: "Edit Context File",
        hint: Keybindings.format(kb.edit_context)
      },
      # Other
      %{id: :integrations, label: "Integrations (connect services)", hint: ""},
      %{id: :refresh, label: "Refresh", hint: Keybindings.format(kb.refresh)},
      %{id: :theme_picker, label: "Choose Theme", hint: ""}
    ]
  end

  defp theme_picker_list do
    Theme.all()
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {_name, theme} -> %{theme: theme} end)
  end

  defp apply_theme_picker(state) do
    theme = Enum.at(theme_picker_list(), state.modal.theme_picker.cursor).theme
    path = Path.join(Path.expand("~/.codrift"), "theme.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"theme" => to_string(theme.name)}))

    %{
      state
      | modal: %{
          state.modal
          | type: :none,
            theme_picker: %{state.modal.theme_picker | before: nil}
        },
        theme: theme
    }
    |> flash_status("Theme: #{theme.name}")
  end
end

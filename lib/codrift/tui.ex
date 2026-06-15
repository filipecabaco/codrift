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
  | `s` | Start agent (context-sensitive; picker when multiple CLIs detected) |
  | `d` | Delete / remove / stop (context-sensitive with confirmation) |
  | `Ctrl+P` | Command palette |
  | `Ctrl+B` | Toggle sidebar (collapse / expand) |
  | `1` | Context mode (default) |
  | `2` | Diff mode for selected initiative |
  | `v` | Toggle diff view: unified ↔ split (diff mode only) |
  | `*` | Reset diff sidebar to "all files" (diff mode only) |
  | `r` | Refresh current pane |
  | `Ctrl+D` / `Ctrl+U` | Scroll half-page |
  | `Ctrl+F` / `Ctrl+B` | Scroll full page (like `less`) |
  | `PgDn` / `PgUp` | Scroll full page |
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
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.CodeBlock
  alias ExRatatui.Widgets.List, as: WidgetList
  alias ExRatatui.Widgets.Paragraph

  alias Codrift.Agent
  alias Codrift.Agent.Adapters.{Claude, Terminal}
  alias Codrift.{AgentProcess, AgentSupervisor, ConductorSupervisor, Diff, Initiative, Paths}
  alias Codrift.Config.{Keybindings, Settings, Theme}
  alias Codrift.Initiative.{DirEntry, Store}
  alias Codrift.OAuth.Config, as: OAuthConfig
  alias Codrift.Worktree

  alias Codrift.TUI.{
    AgentState,
    DirPicker,
    Modals,
    ModalState,
    Selection,
    Sidebar,
    SidebarFilter,
    SidebarState,
    Styles,
    Tree,
    VT100
  }

  @type modal ::
          :none
          | :new_name
          | :new_dir
          | :confirm_delete
          | :palette
          | :theme_picker
          | :new_tree_item
          | :promote_name
          | :new_context_file
          | :integration_item_id
          | :service_guided_token
          | :source_picker
          | :service_auth_url
          | :service_device_flow
          | :service_setup
          | :agent_picker
          | :shortcuts
          | :orchestration_task
  @type tab :: :context | :diff | :tree

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
    modal: %ModalState{},
    diff: %{
      files: [],
      scroll: 0,
      view_mode: :unified,
      sidebar_entries: [],
      sidebar_cursor: 0,
      filter: %{query: "", active: false}
    },
    tree: %{
      entries: [],
      all_files: [],
      cursor: 0,
      expanded: MapSet.new(),
      initiative_id: nil,
      initiative_name: nil,
      filter: %{query: "", active: false}
    },
    temp_initiative: nil,
    vim_editor: nil,
    refs: %{
      resize: nil,
      sidebar_tick: nil,
      status_timer: nil,
      nudge: nil,
      restore: nil,
      output_render: nil,
      scroll_render: nil
    }
  ]

  # Enable X10 + SGR extended mouse reporting so the terminal sends scroll wheel
  # events as proper mouse events rather than converting them to \e[A/\e[B arrow
  # sequences. ExRatatui's NIF does not emit EnableMouseCapture itself.
  @mouse_enable "\e[?1000h\e[?1006h"
  @mouse_disable "\e[?1000l\e[?1006l"

  @impl true
  def mount(opts) do
    temp_initiative = Keyword.get(opts, :temp_initiative)
    IO.write(@mouse_enable)
    Process.send_after(self(), :autostart_sessions, 300)
    Codrift.Updater.check_async(self())
    persisted = Store.list()
    initiatives = if temp_initiative, do: [temp_initiative | persisted], else: persisted
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
      status:
        if(temp_initiative,
          do: build_temp_status(keybindings),
          else: build_default_status(keybindings)
        ),
      input_buffer: "",
      theme: theme,
      kb: %{bindings: keybindings, reverse: keybindings_reverse},
      sidebar: %SidebarState{
        entries: Sidebar.build_entries(initiatives, agents),
        cursor: 0,
        collapsed: false,
        collapsed_ids: MapSet.new()
      },
      selection: %Selection{},
      agents: %AgentState{
        subscribed: MapSet.new(),
        outputs: %{},
        screens: %{}
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
      temp_initiative: temp_initiative,
      diff: %{
        files: [],
        scroll: 0,
        view_mode: :unified,
        sidebar_entries: [],
        sidebar_cursor: 0,
        filter: SidebarFilter.new()
      },
      refs: %{
        resize: nil,
        sidebar_tick: Process.send_after(self(), :sidebar_tick, 2000),
        status_timer: nil,
        nudge: nil,
        restore: nil,
        output_render: nil,
        scroll_render: nil
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

        sidebar_widgets = build_sidebar_widgets(state, sidebar_rect)

        {sidebar_widgets, mr}
      end

    base =
      [{render_mode_bar(state), header_rect}] ++
        sidebar_widgets ++
        [{render_footer(state), footer_rect}]

    base ++ render_main_area(state, main_rect) ++ Modals.render(state, frame)
  end

  @impl true
  def handle_event(%Paste{content: text}, %{vim_editor: %{exec_pid: exec_pid}} = state) do
    :exec.send(exec_pid, text)
    {:noreply, state}
  end

  def handle_event(%Key{kind: "press"} = key, %{vim_editor: %{exec_pid: exec_pid}} = state) do
    raw = key_to_raw(key)
    if raw != "", do: :exec.send(exec_pid, raw)
    {:noreply, state}
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
  # Debounced: batch rapid mouse-wheel events and render at most once per 16 ms.
  def handle_event(%Mouse{kind: "scroll_up"} = ev, %{modal: %{type: :none}} = state) do
    debounce_scroll(mouse_scroll(state, ev, -3))
  end

  def handle_event(%Mouse{kind: "scroll_down"} = ev, %{modal: %{type: :none}} = state) do
    debounce_scroll(mouse_scroll(state, ev, 3))
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

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: %{type: :promote_name}} = state),
    do: {:noreply, confirm_promote(state)}

  def handle_event(
        %Key{code: "enter", kind: "press"},
        %{modal: %{type: :new_tree_item}} = state
      ),
      do: {:noreply, confirm_tree_item(state)}

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

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: %{type: :shortcuts}} = state),
    do: {:noreply, %{state | modal: %{state.modal | type: :none}}}

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

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: %{type: :agent_picker}} = state) do
    cursor = max(state.modal.agent_picker.cursor - 1, 0)

    {:noreply,
     %{state | modal: %{state.modal | agent_picker: %{state.modal.agent_picker | cursor: cursor}}}}
  end

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: %{type: :agent_picker}} = state) do
    max_idx = length(state.modal.context) - 1
    cursor = min(state.modal.agent_picker.cursor + 1, max_idx)

    {:noreply,
     %{state | modal: %{state.modal | agent_picker: %{state.modal.agent_picker | cursor: cursor}}}}
  end

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: %{type: :agent_picker}} = state) do
    adapter = Enum.at(state.modal.context, state.modal.agent_picker.cursor)
    base = %{state | modal: %{state.modal | type: :none}}

    case state.modal.agent_picker[:intent] do
      :start_orchestration ->
        {:noreply,
         open_orchestration_task_modal_with(base, state.modal.agent_picker.initiative_id, adapter)}

      _ ->
        {:noreply, start_agent_at_cursor(base, adapter)}
    end
  end

  def handle_event(
        %Key{code: "enter", kind: "press"},
        %{modal: %{type: :orchestration_task}} = state
      ),
      do: {:noreply, confirm_orchestration_task(state)}

  # Text-input key routing — ADDING A MODAL CHECKLIST
  #
  # If your new modal renders a TextInput widget, add its type atom to BOTH
  # guards below (printable chars + navigation/delete keys). Omitting it
  # silently breaks typing: the key falls through to the no-modal branch.
  #
  # Modals WITHOUT TextInput (pickers, confirmations, info screens) must NOT
  # appear here: :confirm_delete, :source_picker, :theme_picker,
  # :service_auth_url, :service_device_flow, :service_setup.

  def handle_event(%Key{code: code, kind: "press"}, %{modal: %{type: modal}} = state)
      when modal in [
             :new_name,
             :new_dir,
             :palette,
             :new_context_file,
             :new_tree_item,
             :integration_item_id,
             :service_guided_token,
             :promote_name,
             :orchestration_task
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
             :new_tree_item,
             :integration_item_id,
             :service_guided_token,
             :promote_name,
             :orchestration_task
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
  # In tree mode the main pane is a navigable list, not a text input, so Tab always cycles focus.
  def handle_event(%Key{code: "tab", kind: "press"} = key, %{modal: %{type: :none}} = state) do
    cond do
      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\t")}

      Focus.focused?(state.focus, :main) and state.active_tab != :tree ->
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

      agent_pane?(state) ->
        debounce_scroll(%{state | main_scroll: max(state.main_scroll - 10, 0)})

      true ->
        debounce_scroll(%{
          state
          | main_scroll: min(state.main_scroll + 10, non_agent_max_scroll(state))
        })
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

      agent_pane?(state) ->
        debounce_scroll(%{
          state
          | main_scroll: min(state.main_scroll + 10, agent_max_scroll(state))
        })

      true ->
        debounce_scroll(%{state | main_scroll: max(state.main_scroll - 10, 0)})
    end
  end

  # Ctrl+F / Ctrl+B — full-page scroll (like less/man). PTY agents receive the
  # raw bytes; non-PTY panes jump a full pane height at once.
  def handle_event(
        %Key{code: "f", kind: "press", modifiers: ["ctrl"]},
        %{modal: %{type: :none}} = state
      ) do
    {_, pane_h} = state.pane_size

    cond do
      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\x06")}

      state.active_tab == :diff ->
        {:noreply, %{state | diff: %{state.diff | scroll: state.diff.scroll + pane_h}}}

      agent_pane?(state) ->
        debounce_scroll(%{state | main_scroll: max(state.main_scroll - pane_h, 0)})

      true ->
        debounce_scroll(%{
          state
          | main_scroll: min(state.main_scroll + pane_h, non_agent_max_scroll(state))
        })
    end
  end

  def handle_event(
        %Key{code: "b", kind: "press", modifiers: ["ctrl"]},
        %{modal: %{type: :none}} = state
      ) do
    {_, pane_h} = state.pane_size

    cond do
      not Focus.focused?(state.focus, :main) ->
        action = Map.get(state.kb.reverse, "ctrl+b")
        dispatch_sidebar_action(action, state)

      state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\x02")}

      state.active_tab == :diff ->
        {:noreply, %{state | diff: %{state.diff | scroll: max(state.diff.scroll - pane_h, 0)}}}

      agent_pane?(state) ->
        debounce_scroll(%{
          state
          | main_scroll: min(state.main_scroll + pane_h, agent_max_scroll(state))
        })

      true ->
        debounce_scroll(%{state | main_scroll: max(state.main_scroll - pane_h, 0)})
    end
  end

  # PgDn / PgUp — same full-page jump, forwarded as standard sequences to PTY agents.
  def handle_event(%Key{code: "page_down", kind: "press"}, %{modal: %{type: :none}} = state) do
    {_, pane_h} = state.pane_size

    cond do
      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\e[6~")}

      state.active_tab == :diff ->
        {:noreply, %{state | diff: %{state.diff | scroll: state.diff.scroll + pane_h}}}

      agent_pane?(state) ->
        debounce_scroll(%{state | main_scroll: max(state.main_scroll - pane_h, 0)})

      true ->
        debounce_scroll(%{
          state
          | main_scroll: min(state.main_scroll + pane_h, non_agent_max_scroll(state))
        })
    end
  end

  def handle_event(%Key{code: "page_up", kind: "press"}, %{modal: %{type: :none}} = state) do
    {_, pane_h} = state.pane_size

    cond do
      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\e[5~")}

      state.active_tab == :diff ->
        {:noreply, %{state | diff: %{state.diff | scroll: max(state.diff.scroll - pane_h, 0)}}}

      agent_pane?(state) ->
        debounce_scroll(%{
          state
          | main_scroll: min(state.main_scroll + pane_h, agent_max_scroll(state))
        })

      true ->
        debounce_scroll(%{state | main_scroll: max(state.main_scroll - pane_h, 0)})
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
  # In tree mode, Enter toggles expand/collapse of the entry at cursor.
  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: %{type: :none}} = state) do
    cond do
      state.active_tab == :tree ->
        {:noreply, tree_toggle_at_cursor(state)}

      Focus.focused?(state.focus, :main) ->
        case state.selection.agent_mode do
          :pty ->
            {:noreply, forward_raw(state, "\r")}

          _ when state.paste_mode ->
            {:noreply, %{state | input_buffer: state.input_buffer <> "\n"}}

          _ ->
            {:noreply, send_agent_input(state)}
        end

      true ->
        {:noreply, state}
    end
  end

  def handle_event(%Key{code: "esc", kind: "press"}, %{modal: %{type: :none}} = state) do
    cond do
      state.active_tab == :diff and SidebarFilter.visible?(state.diff.filter) ->
        {:noreply,
         %{
           state
           | diff: %{
               state.diff
               | filter: SidebarFilter.deactivate(state.diff.filter),
                 sidebar_cursor: 0
             }
         }}

      state.active_tab == :tree and SidebarFilter.visible?(state.tree.filter) ->
        {:noreply,
         %{
           state
           | tree: %{state.tree | filter: SidebarFilter.deactivate(state.tree.filter), cursor: 0}
         }}

      Focus.focused?(state.focus, :main) ->
        case state.selection.agent_mode do
          :pty -> {:noreply, forward_raw(state, "\e")}
          _ -> {:noreply, flash_status(%{state | input_buffer: ""}, "Input cleared")}
        end

      true ->
        {:noreply, state}
    end
  end

  def handle_event(%Key{code: "backspace", kind: "press"}, %{modal: %{type: :none}} = state) do
    cond do
      state.active_tab == :diff and SidebarFilter.active?(state.diff.filter) ->
        new_filter = SidebarFilter.backspace(state.diff.filter)
        {:noreply, %{state | diff: %{state.diff | filter: new_filter, sidebar_cursor: 0}}}

      state.active_tab == :tree and SidebarFilter.active?(state.tree.filter) ->
        new_filter = SidebarFilter.backspace(state.tree.filter)
        {:noreply, %{state | tree: %{state.tree | filter: new_filter, cursor: 0}}}

      Focus.focused?(state.focus, :main) ->
        case state.selection.agent_mode do
          :pty ->
            {:noreply, forward_raw(state, "\x7f")}

          _ ->
            new_buf = String.slice(state.input_buffer, 0..-2//1)
            {:noreply, %{state | input_buffer: new_buf}}
        end

      true ->
        {:noreply, state}
    end
  end

  # Promote temp initiative — only available when TUI was opened with file args.
  def handle_event(
        %Key{code: "P", kind: "press"},
        %{modal: %{type: :none}, temp_initiative: %Initiative{}} = state
      ) do
    ExRatatui.text_input_set_value(state.modal.input, "")

    {:noreply,
     %{
       state
       | modal: %{state.modal | type: :promote_name},
         status: "Name for this initiative  Enter: save  Esc: cancel"
     }}
  end

  # When the sidebar filter is active in diff/tree mode, all printable chars feed
  # the filter query rather than triggering sidebar actions.
  # Only applies when the sidebar has focus — main-pane actions work normally.
  def handle_event(
        %Key{code: code, kind: "press"},
        %{modal: %{type: :none}, active_tab: tab} = state
      )
      when byte_size(code) == 1 and tab in [:diff, :tree] do
    filter = if tab == :diff, do: state.diff.filter, else: state.tree.filter

    if SidebarFilter.active?(filter) and Focus.focused?(state.focus, :sidebar) do
      new_filter = SidebarFilter.put_char(filter, code)

      new_state =
        if tab == :diff,
          do: %{state | diff: %{state.diff | filter: new_filter, sidebar_cursor: 0}},
          else: %{state | tree: %{state.tree | filter: new_filter, cursor: 0}}

      {:noreply, new_state}
    else
      action = Map.get(state.kb.reverse, code)
      focus = Focus.focused?(state.focus, :main)
      dispatch_char(action, code, focus, state)
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

      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\e[B")}

      state.active_tab == :diff ->
        {:noreply, %{state | diff: %{state.diff | scroll: state.diff.scroll + 3}}}

      agent_pane?(state) ->
        debounce_scroll(%{state | main_scroll: max(state.main_scroll - 3, 0)})

      Focus.focused?(state.focus, :main) ->
        debounce_scroll(%{
          state
          | main_scroll: min(state.main_scroll + 3, non_agent_max_scroll(state))
        })

      true ->
        {:noreply, state}
    end
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: %{type: :none}} = state) do
    cond do
      Focus.focused?(state.focus, :sidebar) ->
        {:noreply, navigate(state, -1)}

      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\e[A")}

      state.active_tab == :diff ->
        {:noreply, %{state | diff: %{state.diff | scroll: max(state.diff.scroll - 3, 0)}}}

      agent_pane?(state) ->
        debounce_scroll(%{
          state
          | main_scroll: min(state.main_scroll + 3, agent_max_scroll(state))
        })

      Focus.focused?(state.focus, :main) ->
        debounce_scroll(%{state | main_scroll: max(state.main_scroll - 3, 0)})

      true ->
        {:noreply, state}
    end
  end

  def handle_event(%Key{code: "right", kind: "press"}, %{modal: %{type: :none}} = state) do
    cond do
      state.active_tab == :tree ->
        {:noreply, tree_expand_at_cursor(state)}

      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\e[C")}

      true ->
        {:noreply, state}
    end
  end

  def handle_event(%Key{code: "left", kind: "press"}, %{modal: %{type: :none}} = state) do
    cond do
      state.active_tab == :tree ->
        {:noreply, tree_collapse_at_cursor(state)}

      Focus.focused?(state.focus, :main) and state.selection.agent_mode == :pty ->
        {:noreply, forward_raw(state, "\e[D")}

      true ->
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

  # Activate sidebar filter with "/" in diff or tree mode.
  # all_files is computed here (lazily) so tab switching stays instant.
  defp dispatch_char(_action, "/", _focus, %{active_tab: :diff} = state),
    do:
      {:noreply,
       %{state | diff: %{state.diff | filter: SidebarFilter.activate(state.diff.filter)}}}

  defp dispatch_char(_action, "/", _focus, %{active_tab: :tree} = state) do
    all_files = load_tree_all_files(state)

    {:noreply,
     %{
       state
       | tree: %{
           state.tree
           | all_files: all_files,
             filter: SidebarFilter.activate(state.tree.filter)
         }
     }}
  end

  # "?" opens the shortcuts pane from sidebar in any mode (not when main PTY is focused).
  defp dispatch_char(_action, "?", false, state),
    do: {:noreply, %{state | modal: %{state.modal | type: :shortcuts}}}

  # Tree mode intercepts — before normal sidebar/PTY routing.
  defp dispatch_char(_action, " ", _focus, %{active_tab: :tree} = state),
    do: {:noreply, tree_toggle_at_cursor(state)}

  defp dispatch_char(:edit_context, _code, _focus, %{active_tab: :tree} = state),
    do: {:noreply, open_tree_file_editor(state)}

  defp dispatch_char(:new_initiative, _code, _focus, %{active_tab: :tree} = state),
    do: {:noreply, open_new_tree_item_modal(state)}

  defp dispatch_char(:delete, _code, _focus, %{active_tab: :tree} = state),
    do: {:noreply, open_tree_delete_confirm(state)}

  defp dispatch_char(:navigate_down, _code, true, %{active_tab: :tree} = state),
    do: debounce_scroll(%{state | main_scroll: state.main_scroll + 3})

  defp dispatch_char(:navigate_up, _code, true, %{active_tab: :tree} = state),
    do: debounce_scroll(%{state | main_scroll: max(state.main_scroll - 3, 0)})

  defp dispatch_char(action, _code, _focus, %{active_tab: :tree} = state),
    do: dispatch_sidebar_action(action, state)

  # PTY forward takes priority over all sidebar actions when main is focused.
  defp dispatch_char(_action, code, true, %{selection: %{agent_mode: :pty}} = state),
    do: {:noreply, forward_raw(state, code)}

  defp dispatch_char(:edit_context, code, true, state) do
    case state.cursor_info do
      %{type: :context_file, path: path} -> {:noreply, open_in_editor(state, path)}
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
    do: {:noreply, move_sidebar_cursor(state, 1)}

  defp dispatch_sidebar_action(:navigate_up, state),
    do: {:noreply, move_sidebar_cursor(state, -1)}

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

  defp dispatch_sidebar_action(:tree_mode, state) do
    {:noreply,
     refresh_tree(%{
       state
       | active_tab: :tree,
         main_scroll: 0,
         focus: Focus.new([:sidebar, :main])
     })}
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
    do: {:noreply, maybe_open_agent_picker(state)}

  defp dispatch_sidebar_action(:start_terminal, state),
    do: {:noreply, start_agent_at_cursor(state, Terminal)}

  defp dispatch_sidebar_action(:new_context, state),
    do: {:noreply, open_new_context_file_modal(state)}

  defp dispatch_sidebar_action(:delete, state),
    do: {:noreply, open_delete_confirm(state)}

  defp dispatch_sidebar_action(:edit_context, state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:context_file, _, path, _} -> {:noreply, open_in_editor(state, path)}
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

  defp dispatch_sidebar_action(:start_orchestration, state),
    do: {:noreply, open_orchestration_task_modal(state)}

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
  def terminate(_reason, _state) do
    IO.write(@mouse_disable)
  end

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

    cursor_hidden_at =
      track_cursor_hidden(
        state.agents.cursor_hidden_at,
        agent_id,
        screen.cursor_visible,
        updated.cursor_visible
      )

    new_state = %{
      state
      | agents: %{
          state.agents
          | screens: new_screens,
            outputs: outputs,
            cursor_hidden_at: cursor_hidden_at
        },
        main_scroll: scroll_for_output(selected, state.main_scroll),
        refs: schedule_output_render(state, selected)
    }

    {:noreply, new_state, [render?: false]}
  end

  def handle_info(:render_output, state) do
    {:noreply, %{state | refs: Map.put(state.refs, :output_render, nil)}, [render?: true]}
  end

  def handle_info(:scroll_render, state) do
    {:noreply, %{state | refs: %{state.refs | scroll_render: nil}}}
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

      new_vim_editor =
        case state.vim_editor do
          %{ospid: ospid, screen: screen} = vim ->
            inner_w = max(pane_w - 2, 10)
            inner_h = max(pane_h - 2, 5)
            :exec.winsz(ospid, inner_h, inner_w)
            %{vim | screen: VT100.resize(screen, inner_w, inner_h)}

          nil ->
            nil
        end

      {:noreply,
       %{
         state
         | pane_size: {pane_w, pane_h},
           agents: %{state.agents | screens: new_screens},
           vim_editor: new_vim_editor,
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
      |> Enum.group_by(fn {_agent_id, initiative_id, dir, _uuid, _adapter} ->
        {initiative_id, dir}
      end)
      |> Enum.reduce({[], []}, fn {_slot, entries}, {keep, drop} ->
        [head | tail] = entries
        {[head | keep], tail ++ drop}
      end)

    Enum.each(to_delete, fn {agent_id, _initiative_id, _dir, _uuid, _adapter} ->
      Codrift.SessionStore.delete_by_agent(agent_id)
    end)

    new_state =
      Enum.reduce(to_start, state, fn {agent_id, initiative_id, dir, _uuid, adapter_name}, acc ->
        case {Store.get(initiative_id), Agent.module_from_name(adapter_name)} do
          {{:ok, _initiative}, adapter} when not is_nil(adapter) ->
            do_start_agent(acc, initiative_id, dir, adapter, agent_id)

          _ ->
            acc
        end
      end)

    {:noreply, new_state}
  end

  def handle_info({:update_available, latest}, state) do
    {:noreply, flash_status(state, "codrift #{latest} available — run `codrift update`", 8000)}
  end

  def handle_info({:stdout, ospid, data}, %{vim_editor: %{ospid: ospid} = vim} = state) do
    updated_screen = VT100.process(vim.screen, data)
    {:noreply, %{state | vim_editor: %{vim | screen: updated_screen}}, [render?: true]}
  end

  def handle_info(
        {:DOWN, ospid, :process, _pid, _reason},
        %{vim_editor: %{ospid: ospid, path: path}} = state
      ) do
    new_state =
      state
      |> Map.put(:vim_editor, nil)
      |> reload_sidebar()
      |> update_context_from_cursor()
      |> flash_status("Edited #{Path.basename(path)}")

    {:noreply, new_state, [render?: true]}
  end

  def handle_info(_, state), do: {:noreply, state}

  # Keeps the live view pinned at the default position while output streams, but
  # preserves the user's position if they've scrolled away (main_scroll > 0).
  defp scroll_for_output(true, main_scroll) when main_scroll > 0, do: main_scroll
  defp scroll_for_output(true, _main_scroll), do: 0
  defp scroll_for_output(false, main_scroll), do: main_scroll

  # Schedules a coalesced render for the selected agent unless one is already pending.
  defp schedule_output_render(state, false), do: state.refs

  defp schedule_output_render(state, true) do
    if is_nil(Map.get(state.refs, :output_render)) do
      ref = Process.send_after(self(), :render_output, 16)
      Map.put(state.refs, :output_render, ref)
    else
      state.refs
    end
  end

  # Records when the cursor became hidden (for blink/idle handling), clearing the
  # timestamp when it reappears.
  defp track_cursor_hidden(map, agent_id, true, false),
    do: Map.put(map, agent_id, :erlang.monotonic_time(:millisecond))

  defp track_cursor_hidden(map, agent_id, false, true), do: Map.delete(map, agent_id)
  defp track_cursor_hidden(map, _agent_id, _was, _now), do: map

  defp save_all_sessions(state) do
    for agent_id <- MapSet.to_list(state.agents.subscribed) do
      try do
        with {:ok, pid} <- AgentSupervisor.find_agent(agent_id),
             status = AgentProcess.status(pid),
             true <- status.adapter.session_persistable?(),
             uuid when not is_nil(uuid) <- AgentProcess.session_uuid(pid) do
          Codrift.SessionStore.save(
            agent_id,
            status.initiative_id,
            status.dir,
            uuid,
            Agent.adapter_name(status.adapter)
          )
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

  defp confirm_promote(%{temp_initiative: initiative} = state) do
    name = String.trim(ExRatatui.text_input_get_value(state.modal.input))

    if name == "" do
      flash_status(state, "Name cannot be empty")
    else
      dirs = Enum.map(initiative.dirs, & &1.path)

      case Store.create(name, dirs) do
        {:ok, _saved} ->
          state
          |> Map.put(:temp_initiative, nil)
          |> Map.update!(:modal, &%{&1 | type: :none})
          |> reload_sidebar()
          |> then(&%{&1 | status: build_default_status(&1.kb.bindings)})
          |> flash_status("Initiative '#{name}' saved")

        {:error, reason} ->
          flash_status(state, "Failed to save: #{inspect(reason)}")
      end
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

  defp do_delete(%{modal: %{context: {:delete_tree_file, path}}} = state) do
    case File.rm(path) do
      :ok ->
        state
        |> then(&%{&1 | modal: %{&1.modal | type: :none, context: nil}})
        |> rebuild_tree()
        |> flash_status("Deleted #{Path.basename(path)}")

      {:error, reason} ->
        flash_status(
          %{state | modal: %{state.modal | type: :none, context: nil}},
          "Delete failed: #{inspect(reason)}"
        )
    end
  end

  defp do_delete(%{modal: %{context: {:delete_tree_dir, path}}} = state) do
    case File.rm_rf(path) do
      {:ok, _} ->
        state
        |> then(&%{&1 | modal: %{&1.modal | type: :none, context: nil}})
        |> rebuild_tree()
        |> flash_status("Deleted #{Path.basename(path)}/")

      {:error, reason, _} ->
        flash_status(
          %{state | modal: %{state.modal | type: :none, context: nil}},
          "Delete failed: #{inspect(reason)}"
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

  defp do_palette_action(:tree_mode, state),
    do:
      refresh_tree(%{
        state
        | modal: %{state.modal | type: :none},
          active_tab: :tree,
          main_scroll: 0,
          focus: Focus.new([:sidebar, :main])
      })

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

  defp do_palette_action(:start_agent, state),
    do: {:noreply, maybe_open_agent_picker(%{state | modal: %{state.modal | type: :none}})}

  defp do_palette_action(:start_terminal, state),
    do: start_agent_at_cursor(%{state | modal: %{state.modal | type: :none}}, Terminal)

  defp do_palette_action(:new_context_file, state),
    do: open_new_context_file_modal(%{state | modal: %{state.modal | type: :none}})

  defp do_palette_action(:edit_context_file, state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:context_file, _, path, _} ->
        open_in_editor(%{state | modal: %{state.modal | type: :none}}, path)

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

  defp do_palette_action(:start_orchestration, state),
    do: open_orchestration_task_modal(%{state | modal: %{state.modal | type: :none}})

  defp do_palette_action(:shortcuts, state),
    do: %{state | modal: %{state.modal | type: :shortcuts}}

  defp do_palette_action(:filter_files, %{active_tab: :diff} = state) do
    %{
      state
      | modal: %{state.modal | type: :none},
        diff: %{state.diff | filter: SidebarFilter.activate(state.diff.filter)}
    }
  end

  defp do_palette_action(:filter_files, %{active_tab: :tree} = state) do
    all_files = load_tree_all_files(state)

    %{
      state
      | modal: %{state.modal | type: :none},
        tree: %{
          state.tree
          | all_files: all_files,
            filter: SidebarFilter.activate(state.tree.filter)
        }
    }
  end

  defp do_palette_action(:filter_files, state),
    do: %{state | modal: %{state.modal | type: :none}}

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

  defp filtered_tree_entries(%{tree: %{filter: filter, entries: entries, all_files: all_files}}) do
    SidebarFilter.apply_tree(filter, all_files, entries)
  end

  defp tree_entry_at_cursor(state) do
    Enum.at(filtered_tree_entries(state), state.tree.cursor)
  end

  defp load_tree_all_files(%{tree: %{all_files: [_ | _] = files}}), do: files

  defp load_tree_all_files(%{tree: %{initiative_id: id}}) when not is_nil(id) do
    case Store.get(id) do
      {:ok, initiative} -> Tree.all_files(initiative)
      _ -> []
    end
  end

  defp load_tree_all_files(_), do: []

  defp visible_diff_entries(%{diff: %{filter: filter, sidebar_entries: entries}}) do
    SidebarFilter.apply_diff(filter, entries)
  end

  # Always moves the sidebar cursor — used by j/k keybindings so the focus check
  # inside navigate/2 cannot accidentally fall through to main-pane scrolling.
  defp move_sidebar_cursor(state, delta) do
    cond do
      state.active_tab == :diff ->
        entries = visible_diff_entries(state)
        max_idx = max(length(entries) - 1, 0)
        new_cursor = min(max(state.diff.sidebar_cursor + delta, 0), max_idx)
        %{state | diff: %{state.diff | sidebar_cursor: new_cursor, scroll: 0}}

      state.active_tab == :tree ->
        move_tree_cursor(state, delta)

      true ->
        max_idx = max(length(state.sidebar.entries) - 1, 0)
        new_cursor = min(max(state.sidebar.cursor + delta, 0), max_idx)

        %{state | sidebar: %{state.sidebar | cursor: new_cursor}, main_scroll: 0}
        |> update_context_from_cursor()
    end
  end

  defp navigate(state, delta) do
    if Focus.focused?(state.focus, :sidebar) do
      cond do
        state.active_tab == :diff ->
          # In diff mode the sidebar shows diff entries; navigate those independently.
          max_idx = max(length(state.diff.sidebar_entries) - 1, 0)
          new_cursor = min(max(state.diff.sidebar_cursor + delta, 0), max_idx)
          %{state | diff: %{state.diff | sidebar_cursor: new_cursor, scroll: 0}}

        state.active_tab == :tree ->
          move_tree_cursor(state, delta)

        true ->
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

        line_count =
          build_initiative_md_content(
            md_sections,
            dir_infos,
            context_files,
            context_dir,
            initiative.worktree_default || false
          )
          |> String.split("\n")
          |> length()

        cursor_info = %{
          type: :initiative,
          name: initiative.name,
          id: initiative.id,
          status: initiative.status || :ongoing,
          context_dir: context_dir,
          context_files: context_files,
          dirs: dir_infos,
          md_sections: md_sections,
          worktree_default: initiative.worktree_default,
          line_count: line_count
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

    lines = String.split(content, "\n")
    cursor_info = %{type: :context_file, path: path, content: content, lines: lines}

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

          # Ink/Bubble Tea TUIs: only replay from last \e[2J anchor — IL/DL need scroll-region context.
          # Terminal/shell: replay all output — shells never send \e[2J to draw their prompt.
          replay =
            if status.adapter.tui?(),
              do: chunks_from_last_clear(existing),
              else: existing

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

  # TUI adapters (tui?/0 = true): two-step resize forces a full \e[2J repaint.
  # A nudge fires at 600 ms only when there's no existing output (slow-starting agents).
  # Cancel stale timers from any previous subscription first.
  # Terminal/shell adapters: a single resize suffices — two-step causes extra shell prompts.
  defp setup_agent_refs(state, pid, agent_id, replay, adapter, {w, h}) do
    if adapter.tui?() do
      if state.refs.nudge, do: Process.cancel_timer(state.refs.nudge)
      if state.refs.restore, do: Process.cancel_timer(state.refs.restore)
      AgentProcess.resize(pid, max(w - 1, 1), h)
      restore_ref = Process.send_after(self(), {:restore_agent_size, agent_id, w, h}, 150)

      nudge_ref =
        if Enum.empty?(replay),
          do: Process.send_after(self(), {:nudge_agent, agent_id, w, h}, 600)

      %{state.refs | nudge: nudge_ref, restore: restore_ref}
    else
      AgentProcess.resize(pid, w, h)
      state.refs
    end
  end

  # TUI adapters: content starts at row 0 — no leading blank lines.
  # Terminal/shell adapters: zsh/starship emit \n before each prompt, so skip to first content.
  defp agent_initial_scroll(adapter, screen) do
    if adapter.tui?(), do: 0, else: VT100.first_content_row(screen)
  end

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

  defp maybe_open_agent_picker(state) do
    case Agent.available_adapters() do
      [single] ->
        start_agent_at_cursor(state, single)

      adapters ->
        counts = Settings.adapter_start_counts()
        sorted = Enum.sort_by(adapters, &Map.get(counts, Agent.adapter_name(&1), 0), :desc)

        %{
          state
          | modal: %{
              state.modal
              | type: :agent_picker,
                context: sorted,
                agent_picker: %{cursor: 0}
            }
        }
    end
  end

  defp do_start_agent(state, initiative_id, dir, adapter, agent_id \\ nil) do
    Settings.increment_adapter_start(adapter)
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
        apply_worktree_default_toggle(state, initiative_id, not initiative.worktree_default)

      _ ->
        state
    end
  end

  defp apply_worktree_default_toggle(state, initiative_id, new_default) do
    case Store.set_worktree_default(initiative_id, new_default) do
      {:ok, _} ->
        label = if new_default, do: "ON", else: "OFF"
        flash_status(state, "Worktree default #{label} for this initiative")

      {:error, reason} ->
        flash_status(state, "Failed: #{inspect(reason)}")
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

  defp open_orchestration_task_modal(state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:initiative, id, _, _, _, _} ->
        case Agent.available_adapters() do
          [] ->
            flash_status(
              state,
              "No agents available — install claude, codex, or another supported CLI"
            )

          [single] ->
            open_orchestration_task_modal_with(state, id, single)

          adapters ->
            counts = Settings.adapter_start_counts()
            sorted = Enum.sort_by(adapters, &Map.get(counts, Agent.adapter_name(&1), 0), :desc)

            %{
              state
              | modal: %{
                  state.modal
                  | type: :agent_picker,
                    context: sorted,
                    agent_picker: %{cursor: 0, intent: :start_orchestration, initiative_id: id}
                }
            }
        end

      _ ->
        flash_status(state, "Navigate to an initiative first")
    end
  end

  defp open_orchestration_task_modal_with(state, initiative_id, adapter) do
    default_task =
      initiative_id
      |> Store.context_path()
      |> Path.join("initiative.md")
      |> File.read()
      |> case do
        {:ok, content} -> String.trim(content)
        {:error, _} -> ""
      end

    ExRatatui.text_input_set_value(state.modal.input, default_task)

    %{
      state
      | modal: %{
          state.modal
          | type: :orchestration_task,
            context: %{initiative_id: initiative_id, adapter: adapter}
        },
        status: "Enter task description — Enter: start  Esc: cancel"
    }
  end

  defp confirm_orchestration_task(
         %{modal: %{context: %{initiative_id: initiative_id, adapter: adapter}}} = state
       ) do
    task = state.modal.input |> ExRatatui.text_input_get_value() |> String.trim()
    base = %{state | modal: %{state.modal | type: :none, context: nil}}

    if task == "" do
      flash_status(base, "Task cannot be empty")
    else
      case Store.get(initiative_id) do
        {:ok, initiative} -> do_start_orchestration(base, initiative, adapter, task)
        {:error, :not_found} -> flash_status(base, "Initiative not found")
      end
    end
  end

  defp confirm_orchestration_task(state),
    do: %{state | modal: %{state.modal | type: :none, context: nil}}

  defp do_start_orchestration(base, initiative, adapter, task) do
    case ConductorSupervisor.start_orchestration(initiative, adapter, task) do
      {:ok, _pid} ->
        base
        |> reload_sidebar()
        |> flash_status("Orchestration started for '#{initiative.name}'")

      {:error, {:already_started, _}} ->
        flash_status(base, "Conductor already running for this initiative")

      {:error, reason} ->
        flash_status(base, "Failed to start orchestration: #{inspect(reason)}")
    end
  end

  defp refresh_current(%{active_tab: :diff} = state), do: refresh_diff(state)
  defp refresh_current(%{active_tab: :tree} = state), do: rebuild_tree(state)

  defp refresh_current(state) do
    state |> reload_sidebar() |> update_context_from_cursor()
  end

  # ── Tree view helpers ─────────────────────────────────────────────────────────

  # Builds tree entries from the initiative at the current sidebar cursor.
  # Resets the expanded set when switching to a different initiative.
  defp refresh_tree(state) do
    id = initiative_id_from_sidebar_cursor(state)

    case id && Store.get(id) do
      {:ok, initiative} ->
        expanded = if id == state.tree.initiative_id, do: state.tree.expanded, else: MapSet.new()
        entries = Tree.build_visible(initiative, expanded)

        %{
          state
          | tree: %{
              state.tree
              | entries: entries,
                all_files: [],
                initiative_id: id,
                initiative_name: initiative.name,
                cursor: 0,
                expanded: expanded,
                filter: SidebarFilter.new()
            }
        }

      _ ->
        %{
          state
          | tree: %{
              state.tree
              | entries: [],
                all_files: [],
                initiative_id: nil,
                initiative_name: nil,
                cursor: 0
            }
        }
    end
  end

  # Rebuilds tree entries in place, preserving cursor and expanded state.
  defp rebuild_tree(state) do
    case state.tree.initiative_id && Store.get(state.tree.initiative_id) do
      {:ok, initiative} ->
        entries = Tree.build_visible(initiative, state.tree.expanded)
        visible = SidebarFilter.apply_tree(state.tree.filter, state.tree.all_files, entries)
        max_cursor = max(length(visible) - 1, 0)

        %{
          state
          | tree: %{
              state.tree
              | entries: entries,
                cursor: min(state.tree.cursor, max_cursor)
            }
        }

      _ ->
        state
    end
  end

  defp move_tree_cursor(state, delta) do
    visible = filtered_tree_entries(state)
    max_idx = max(length(visible) - 1, 0)
    new_cursor = min(max(state.tree.cursor + delta, 0), max_idx)
    %{state | tree: %{state.tree | cursor: new_cursor}, main_scroll: 0}
  end

  defp tree_toggle_at_cursor(state) do
    case tree_entry_at_cursor(state) do
      {:tree_dir, path, _depth, _expanded?} ->
        new_expanded = Tree.toggle_expand(state.tree.expanded, path)
        rebuild_tree(%{state | tree: %{state.tree | expanded: new_expanded}})

      _ ->
        state
    end
  end

  defp tree_expand_at_cursor(state) do
    case tree_entry_at_cursor(state) do
      {:tree_dir, path, _depth, false} ->
        new_expanded = MapSet.put(state.tree.expanded, path)
        rebuild_tree(%{state | tree: %{state.tree | expanded: new_expanded}})

      _ ->
        state
    end
  end

  defp tree_collapse_at_cursor(state) do
    case tree_entry_at_cursor(state) do
      {:tree_dir, path, _depth, true} ->
        new_expanded = MapSet.delete(state.tree.expanded, path)
        rebuild_tree(%{state | tree: %{state.tree | expanded: new_expanded}})

      _ ->
        state
    end
  end

  defp initiative_id_from_sidebar_cursor(state) do
    case Enum.at(state.sidebar.entries, state.sidebar.cursor) do
      {:initiative, id, _, _, _, _} -> id
      {:dir, id, _, _, _} -> id
      {:context_dir, id, _, _} -> id
      {:context_file, id, _, _} -> id
      _ -> nil
    end
  end

  defp open_tree_file_editor(state) do
    case tree_entry_at_cursor(state) do
      {:tree_file, path, _depth} -> open_in_editor(state, path)
      _ -> flash_status(state, "Select a file to open")
    end
  end

  defp open_new_tree_item_modal(state) do
    case tree_cursor_parent_path(state) do
      nil ->
        flash_status(state, "Navigate to a directory first")

      parent ->
        ExRatatui.text_input_set_value(state.modal.input, "")

        %{
          state
          | modal: %{state.modal | type: :new_tree_item, context: {:new_tree_item, parent}},
            status: "Name (append / for dir) — Enter: create  Esc: cancel"
        }
    end
  end

  defp tree_cursor_parent_path(state) do
    case tree_entry_at_cursor(state) do
      {:tree_dir, path, _depth, _expanded?} -> path
      {:tree_file, path, _depth} -> Path.dirname(path)
      nil -> nil
    end
  end

  defp open_tree_delete_confirm(state) do
    case tree_entry_at_cursor(state) do
      {:tree_dir, path, _depth, _expanded?} ->
        %{
          state
          | modal: %{state.modal | type: :confirm_delete, context: {:delete_tree_dir, path}}
        }

      {:tree_file, path, _depth} ->
        %{
          state
          | modal: %{state.modal | type: :confirm_delete, context: {:delete_tree_file, path}}
        }

      nil ->
        flash_status(state, "Navigate to an item first")
    end
  end

  defp confirm_tree_item(%{modal: %{context: {:new_tree_item, parent}}} = state) do
    name = state.modal.input |> ExRatatui.text_input_get_value() |> String.trim()

    cond do
      name == "" ->
        flash_status(state, "Name cannot be empty")

      String.contains?(name, "..") ->
        flash_status(state, "Name must not contain '..'")

      String.ends_with?(name, "/") ->
        dir_name = String.trim_trailing(name, "/")
        path = Path.join(parent, dir_name)

        case File.mkdir_p(path) do
          :ok ->
            state
            |> then(&%{&1 | modal: %{&1.modal | type: :none, context: nil}})
            |> rebuild_tree()
            |> flash_status("Created #{dir_name}/")

          {:error, reason} ->
            flash_status(
              %{state | modal: %{state.modal | type: :none, context: nil}},
              "Failed: #{inspect(reason)}"
            )
        end

      true ->
        path = Path.join(parent, name)

        case File.write(path, "") do
          :ok ->
            state
            |> then(&%{&1 | modal: %{&1.modal | type: :none, context: nil}})
            |> rebuild_tree()
            |> flash_status("Created #{name}")

          {:error, reason} ->
            flash_status(
              %{state | modal: %{state.modal | type: :none, context: nil}},
              "Failed: #{inspect(reason)}"
            )
        end
    end
  end

  defp confirm_tree_item(state),
    do: %{state | modal: %{state.modal | type: :none, context: nil}}

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
    persisted = Store.list()

    initiatives =
      if state.temp_initiative,
        do: [state.temp_initiative | persisted],
        else: persisted

    agents =
      AgentSupervisor.list_agents()
      |> Enum.flat_map(fn pid ->
        try do
          [AgentProcess.status(pid)]
        catch
          :exit, _ -> []
        end
      end)

    full_entries = Sidebar.build_entries(initiatives, agents)
    filtered = Sidebar.filter_entries(full_entries, state.sidebar.collapsed_ids)
    max_idx = max(length(filtered) - 1, 0)
    new_cursor = min(state.sidebar.cursor, max_idx)

    %{state | sidebar: %{state.sidebar | entries: filtered, cursor: new_cursor}}
  end

  defp render_mode_bar(state) do
    {context_style, diff_style, tree_style} =
      case state.active_tab do
        :context ->
          {%Style{fg: :yellow, modifiers: [:bold]}, %Style{fg: :dark_gray},
           %Style{fg: :dark_gray}}

        :diff ->
          {%Style{fg: :dark_gray}, %Style{fg: :yellow, modifiers: [:bold]},
           %Style{fg: :dark_gray}}

        :tree ->
          {%Style{fg: :dark_gray}, %Style{fg: :dark_gray},
           %Style{fg: :yellow, modifiers: [:bold]}}
      end

    %ExRatatui.Widgets.Paragraph{
      text: %ExRatatui.Text{
        lines: [
          %Line{
            spans: [
              %Span{content: " 1: Context ", style: context_style},
              %Span{content: " │ ", style: %Style{fg: :dark_gray}},
              %Span{content: "2: Diff ", style: diff_style},
              %Span{content: " │ ", style: %Style{fg: :dark_gray}},
              %Span{content: "3: Tree ", style: tree_style}
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
        content =
          build_initiative_md_content(md_sections, dirs, files, ctx_dir, wt_default)
          |> String.replace_invalid()

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
        content =
          build_initiative_md_content([], dirs, files, ctx_dir, false) |> String.replace_invalid()

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

  defp render_file_widget(state, path, content) do
    block = %Block{
      title: " #{Path.basename(path)}  e: edit  d: delete ",
      borders: [:all],
      border_type: :rounded,
      border_style: Styles.pane_border(state.focus, :main, state.theme)
    }

    cond do
      content == "" ->
        %Paragraph{text: "(empty file — press e to edit)", block: block, wrap: true}

      not String.valid?(content) ->
        %Paragraph{text: "(binary file — cannot display as text)", block: block, wrap: true}

      true ->
        {_, pane_h} = state.pane_size
        lines = Map.get(state.cursor_info, :lines) || String.split(content, "\n")
        total = length(lines)
        # Clamp scroll to a valid range so we never request past EOF.
        start = min(state.main_scroll, max(total - pane_h, 0))
        visible = Enum.slice(lines, start, pane_h)

        # Pass only the visible window to the syntect NIF so it processes
        # O(pane_h) lines regardless of file size. starting_line keeps
        # line numbers accurate; scroll stays at 0 since we pre-slice.
        %CodeBlock{
          content: Enum.join(visible, "\n"),
          language: detect_language(path),
          theme: state.theme.syntax_theme,
          line_numbers: true,
          starting_line: start + 1,
          block: block,
          scroll: {0, 0}
        }
    end
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
    scrollback_count = length(screen.scrollback)
    n_history = min(state.main_scroll, scrollback_count)

    # Only show the prompt input at live view (n_history=0); hide it when reading history.
    prompt_suffix =
      if n_history == 0 and focused and state.selection.agent_mode != :pty and
           state.input_buffer != "",
         do: "\n> #{state.input_buffer}▌",
         else: ""

    # to_text_viewport produces exactly screen.height lines: the last n_history rows from
    # scrollback above the first (screen.height - n_history) rows of the live screen.
    # This keeps text size O(pane_h) regardless of scrollback depth, avoiding large
    # paragraph renders on every scroll event.
    content =
      if prompt_suffix == "" do
        VT100.to_text_viewport(screen, focused, n_history)
      else
        VT100.to_text_viewport(screen, false, n_history) |> append_prompt(prompt_suffix)
      end

    extra_lines =
      if prompt_suffix == "", do: 0, else: length(String.split(prompt_suffix, "\n"))

    %Paragraph{text: content, block: block, wrap: false, scroll: {extra_lines, 0}}
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

  defp render_main_area(%{vim_editor: vim_editor} = state, rect) when not is_nil(vim_editor) do
    [{render_vim_pane(state), rect}]
  end

  defp render_main_area(%{active_tab: :diff} = state, rect) do
    render_diff_content(state, rect)
  end

  defp render_main_area(%{active_tab: :tree} = state, rect) do
    render_tree_content(state, rect)
  end

  defp render_main_area(state, rect) do
    [{render_main(state), rect}]
  end

  defp render_vim_pane(state) do
    border = Styles.pane_border(state.focus, :main, state.theme)

    block = %Block{
      title: " vim — #{Path.basename(state.vim_editor.path)} ",
      borders: [:all],
      border_type: :rounded,
      border_style: border
    }

    content = VT100.to_text_viewport(state.vim_editor.screen, true, 0)
    %Paragraph{text: content, block: block, wrap: false, scroll: {0, 0}}
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
            else: files |> Enum.map_join("\n", &Diff.to_unified/1) |> String.replace_invalid()

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
  # sidebar cursor position, respecting any active filter.
  defp diff_files_for_cursor(%{diff: %{files: []}}), do: []

  defp diff_files_for_cursor(%{diff: %{files: dir_diffs}} = state) do
    entries = visible_diff_entries(state)
    all_files = Enum.flat_map(dir_diffs, fn {_, files} -> files end)

    case Enum.at(entries, state.diff.sidebar_cursor) do
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
    entry = Enum.at(visible_diff_entries(state), state.diff.sidebar_cursor)
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

  defp build_sidebar_widgets(%{active_tab: :diff} = state, sidebar_rect) do
    filter = state.diff.filter
    filtered = visible_diff_entries(state)
    cursor = min(state.diff.sidebar_cursor, max(length(filtered) - 1, 0))
    list = Sidebar.render_diff(filtered, cursor, state.focus, state.theme)
    with_filter_widget(filter, list, sidebar_rect, state)
  end

  defp build_sidebar_widgets(%{active_tab: :tree} = state, sidebar_rect) do
    filter = state.tree.filter
    filtered = filtered_tree_entries(state)
    cursor = min(state.tree.cursor, max(length(filtered) - 1, 0))
    list = render_tree_sidebar(state, filtered, cursor)
    with_filter_widget(filter, list, sidebar_rect, state)
  end

  defp build_sidebar_widgets(state, sidebar_rect) do
    widget =
      Sidebar.render(
        state.sidebar.entries,
        state.sidebar.cursor,
        state.focus,
        state.theme,
        state.sidebar.collapsed_ids
      )

    [{widget, sidebar_rect}]
  end

  defp with_filter_widget(filter, list, sidebar_rect, state) do
    if SidebarFilter.visible?(filter) do
      [fr, lr] = Layout.split(sidebar_rect, :vertical, [{:length, 3}, {:min, 0}])
      [{render_sidebar_filter(filter, state.focus, state.theme), fr}, {list, lr}]
    else
      [{list, sidebar_rect}]
    end
  end

  # ── Tree sidebar and content pane ─────────────────────────────────────────────

  defp render_sidebar_filter(filter, focus, theme) do
    cursor = if filter.active, do: "|", else: ""

    {prefix, hint} =
      case SidebarFilter.mode(filter) do
        :fuzzy -> {"/ ", "fuzzy"}
        :glob -> {"", "glob  e.g. *.test.ts"}
        :regex -> {"", "regex  e.g. /\\.ex$/"}
        :tag -> {"", "tag  #test #config #doc #schema #router"}
      end

    label = if filter.query == "", do: "#{prefix}#{cursor}", else: "#{filter.query}#{cursor}"

    %Paragraph{
      text: %ExRatatui.Text{
        lines: [
          %Line{
            spans: [
              %Span{content: label, style: %Style{fg: :yellow}},
              %Span{content: "  #{hint}", style: %Style{fg: :dark_gray}}
            ]
          }
        ]
      },
      block: %Block{
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(focus, :sidebar, theme)
      }
    }
  end

  defp render_tree_sidebar(state, entries, cursor) do
    border = Styles.pane_border(state.focus, :sidebar, state.theme)
    title = tree_view_title(state)

    if entries == [] do
      %Paragraph{
        text: %ExRatatui.Text{
          lines: [
            %Line{
              spans: [
                %Span{
                  content: "  No directories — add a directory with 'a'.",
                  style: %Style{fg: :dark_gray}
                }
              ]
            }
          ]
        },
        block: %Block{
          title: title,
          borders: [:all],
          border_type: :rounded,
          border_style: border
        }
      }
    else
      item_fn =
        if SidebarFilter.filtering?(state.tree.filter),
          do: &tree_filter_item/1,
          else: &tree_item/1

      %WidgetList{
        items: Enum.map(entries, item_fn),
        selected: cursor,
        block: %Block{
          title: title,
          borders: [:all],
          border_type: :rounded,
          border_style: border
        },
        highlight_style: Styles.sidebar_highlight(state.theme),
        highlight_symbol: "▶ "
      }
    end
  end

  defp render_tree_content(state, rect) do
    border = Styles.pane_border(state.focus, :main, state.theme)

    widget =
      case Enum.at(filtered_tree_entries(state), state.tree.cursor) do
        {:tree_file, path, _depth} ->
          content =
            case File.read(path) do
              {:ok, text} -> text
              {:error, _} -> "Unable to read file."
            end

          %CodeBlock{
            content: content,
            language: path_to_language(path),
            theme: state.theme.syntax_theme,
            scroll: {state.main_scroll, 0},
            block: %Block{
              title: " #{Path.basename(path)} ",
              borders: [:all],
              border_type: :rounded,
              border_style: border
            }
          }

        {:tree_dir, path, _depth, _expanded?} ->
          %Paragraph{
            text: %ExRatatui.Text{
              lines: [
                %Line{
                  spans: [%Span{content: "  #{path}", style: %Style{fg: :dark_gray}}]
                }
              ]
            },
            block: %Block{
              title: " Directory ",
              borders: [:all],
              border_type: :rounded,
              border_style: border
            }
          }

        nil ->
          %Paragraph{
            text: %ExRatatui.Text{
              lines: [
                %Line{
                  spans: [
                    %Span{content: "  Select a file to preview.", style: %Style{fg: :dark_gray}}
                  ]
                }
              ]
            },
            block: %Block{
              title: " Preview ",
              borders: [:all],
              border_type: :rounded,
              border_style: border
            }
          }
      end

    [{widget, rect}]
  end

  @ext_to_language %{
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".erl" => "erlang",
    ".hrl" => "erlang",
    ".js" => "javascript",
    ".jsx" => "javascript",
    ".ts" => "javascript",
    ".tsx" => "javascript",
    ".py" => "python",
    ".rb" => "ruby",
    ".rs" => "rust",
    ".go" => "go",
    ".java" => "java",
    ".kt" => "java",
    ".kts" => "java",
    ".scala" => "scala",
    ".cs" => "c#",
    ".lua" => "lua",
    ".hs" => "haskell",
    ".ml" => "ocaml",
    ".mli" => "ocaml",
    ".el" => "lisp",
    ".lisp" => "lisp",
    ".php" => "php",
    ".pl" => "perl",
    ".pm" => "perl",
    ".r" => "r",
    ".R" => "r",
    ".tcl" => "tcl",
    ".groovy" => "groovy",
    ".swift" => "javascript",
    ".c" => "c",
    ".h" => "c",
    ".cpp" => "c++",
    ".cc" => "c++",
    ".cxx" => "c++",
    ".hpp" => "c++",
    ".m" => "objective-c",
    ".d" => "d",
    ".json" => "json",
    ".yaml" => "yaml",
    ".yml" => "yaml",
    ".toml" => "toml",
    ".xml" => "xml",
    ".html" => "html",
    ".css" => "css",
    ".scss" => "css",
    ".md" => "markdown",
    ".sh" => "bash",
    ".bash" => "bash",
    ".zsh" => "bash",
    ".fish" => "bash",
    ".sql" => "sql",
    ".diff" => "diff",
    ".patch" => "diff"
  }

  defp path_to_language(path) do
    Map.get(@ext_to_language, Path.extname(path), "text")
  end

  defp tree_view_title(state) do
    if state.tree.initiative_name,
      do: " Tree: #{state.tree.initiative_name} ",
      else: " Tree "
  end

  defp tree_item({:tree_dir, path, depth, expanded?}) do
    sym = if expanded?, do: "▼", else: "▶"
    indent = String.duplicate("  ", depth)

    %Line{
      spans: [
        %Span{content: "#{indent}#{sym} ", style: %Style{fg: :cyan}},
        %Span{content: Path.basename(path), style: %Style{fg: :white, modifiers: [:bold]}}
      ]
    }
  end

  defp tree_item({:tree_file, path, depth}) do
    indent = String.duplicate("  ", depth)

    %Line{
      spans: [
        %Span{content: "#{indent}  – ", style: %Style{fg: :dark_gray}},
        %Span{content: Path.basename(path), style: %Style{fg: :white}}
      ]
    }
  end

  # In filter mode show the relative path (last depth+1 components, capped at 4)
  # so the user can distinguish files with the same basename.
  defp tree_filter_item({:tree_file, path, depth}) do
    n = min(depth + 1, 4)
    rel = path |> Path.split() |> Enum.take(-n) |> Path.join()

    %Line{
      spans: [
        %Span{content: "  – ", style: %Style{fg: :dark_gray}},
        %Span{content: rel, style: %Style{fg: :white}}
      ]
    }
  end

  # Scroll whichever pane the mouse cursor is over.
  # If the pointer is in the sidebar column, scroll the sidebar (navigate).
  # If it's in the main pane and the agent is a PTY, forward scroll as
  # arrow keys so the shell/Claude gets the scroll event natively.
  # Otherwise adjust main_scroll for code-viewer / initiative panes.
  defp mouse_scroll(state, %Mouse{x: x}, delta) do
    {term_w, _} = state.term_size || {80, 24}
    sidebar_width = if state.sidebar.collapsed, do: 0, else: round(term_w * 0.30)

    cond do
      x < sidebar_width and state.active_tab == :tree ->
        move_tree_cursor(state, delta)

      x < sidebar_width ->
        # Scrolling over the sidebar navigates its cursor
        new_cursor =
          (state.sidebar.cursor + delta)
          |> max(0)
          |> min(max(length(state.sidebar.entries) - 1, 0))

        %{state | sidebar: %{state.sidebar | cursor: new_cursor}}
        |> update_context_from_cursor()

      true ->
        # All main-pane content (including PTY agents): move main_scroll.
        # PTY agents previously forwarded scroll as arrow sequences, which
        # navigated Claude's input history instead of scrolling the codrift
        # window — wrong UX.
        # For the agent scrollback pane, main_scroll is "depth into history"
        # (0 = live), so the wheel direction is inverted vs. doc-scroll panes.
        # Cap at scrollback_count to prevent silent accumulation when no history exists.
        if agent_pane?(state) do
          new_scroll = max(state.main_scroll - delta, 0)
          capped = min(new_scroll, agent_max_scroll(state))
          %{state | main_scroll: capped}
        else
          new_scroll = max(state.main_scroll + delta, 0)
          %{state | main_scroll: min(new_scroll, non_agent_max_scroll(state))}
        end
    end
  end

  defp forward_raw(state, data) do
    screen = Map.get(state.agents.screens, state.selection.agent_id)

    # Claude Code hides the cursor (\e[?25l) during Ink repaints and shows it
    # (\e[?25h) when done. Forwarding mid-repaint lands keystrokes at the wrong
    # row. Guard input for Claude only during the brief repaint window (< 250 ms
    # after the cursor hides). Permission dialogs keep the cursor hidden for
    # seconds and must receive input — only time-bounding the guard handles both.
    adapter = lookup_adapter(state, state.selection.agent_id)

    in_repaint_window =
      case Map.get(state.agents.cursor_hidden_at, state.selection.agent_id) do
        nil -> false
        hidden_at -> :erlang.monotonic_time(:millisecond) - hidden_at < 250
      end

    claude_repaint_guard =
      adapter == Claude and screen != nil and not screen.cursor_visible and in_repaint_window

    unless claude_repaint_guard do
      with id when not is_nil(id) <- state.selection.agent_id,
           {:ok, pid} <- AgentSupervisor.find_agent(id) do
        AgentProcess.send_raw(pid, data)
      end
    end

    state
  end

  defp lookup_adapter(_state, nil), do: nil

  defp lookup_adapter(_state, agent_id) do
    case AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} -> AgentProcess.status(pid).adapter
      _ -> nil
    end
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

  defp render_placeholder(%{sidebar: %{entries: []}} = state) do
    %Paragraph{
      text: """
      Welcome to Codrift!

      No initiatives yet. Here's how to get started:

        n  — New initiative (blank or imported from a service)
        a  — Add a directory to the selected initiative
        s  — Start an agent in the selected directory

      An initiative groups one or more directories under a shared context.
      Create one, add a directory, then start an agent to begin.

      Integrations — import initiatives directly from:

        GitHub Issues · GitHub Projects v2
        Linear Issues · Linear Projects
        GitLab Issues · Jira Cloud · Notion

      Press n and choose a service to connect and import.
      Use Ctrl+P → Integrations to manage service connections.
      """,
      block: %Block{
        title: " Getting Started ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(state.focus, :main, state.theme)
      },
      wrap: true
    }
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

  # ── External editor helpers ──────────────────────────────────────────────────

  # Dialyzer cannot trace through :exec.run/2's return type from erlexec.
  @dialyzer {:nowarn_function, open_in_editor: 2}
  defp open_in_editor(state, path) do
    editor = System.get_env("EDITOR", "vim")
    editor_bin = System.find_executable(editor) || editor
    {w, h} = state.pane_size
    # Subtract 2 for the block border so vim sees the usable area
    inner_w = max(w - 2, 10)
    inner_h = max(h - 2, 5)
    cmd = [editor_bin, path]

    pty_opts = [
      :pty,
      {:winsz, {inner_h, inner_w}},
      :stdin,
      {:stdout, self()},
      :monitor,
      {:env, [{"TERM", "xterm-256color"}]}
    ]

    case :exec.run(cmd, pty_opts) do
      {:ok, exec_pid, ospid} ->
        vim_editor = %{
          exec_pid: exec_pid,
          ospid: ospid,
          screen: VT100.new(inner_w, inner_h),
          path: path
        }

        %{state | vim_editor: vim_editor}
        |> flash_status("Editing #{Path.basename(path)} in #{editor} — :q to close")

      {:error, reason} ->
        flash_status(state, "Failed to open editor: #{inspect(reason)}")
    end
  end

  @key_sequences %{
    "enter" => "\r",
    "esc" => "\e",
    "backspace" => "\x7f",
    "tab" => "\t",
    "up" => "\e[A",
    "down" => "\e[B",
    "right" => "\e[C",
    "left" => "\e[D",
    "page_up" => "\e[5~",
    "page_down" => "\e[6~",
    "home" => "\e[H",
    "end" => "\e[F",
    "delete" => "\e[3~"
  }

  defp key_to_raw(%Key{code: code, modifiers: modifiers}) do
    cond do
      "ctrl" in modifiers and byte_size(code) == 1 ->
        <<:binary.first(code) - ?a + 1>>

      Map.has_key?(@key_sequences, code) ->
        @key_sequences[code]

      byte_size(code) == 1 ->
        code

      true ->
        ""
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

        if agent_status.adapter.tui?() do
          {w, h} = state.pane_size
          Process.send_after(self(), {:nudge_agent, agent_id, w, h}, 80)
        end

        agent_status.mode

      _ ->
        state.selection.agent_mode
    end
  end

  # Returns true when the main pane is showing agent output (any mode).
  # In that mode main_scroll is "depth into scrollback history" (0 = live),
  # so UP/DOWN semantics are inverted vs. the CodeBlock/Paragraph panes where
  # main_scroll is the paragraph row offset (higher = further down in the doc).
  # PTY agents (Claude, Terminal) still have their arrow keys forwarded to the
  # PTY in earlier cond branches; this guard only affects the fallthrough cases
  # (Ctrl+D/U and mouse scroll) that modify main_scroll directly.
  defp agent_pane?(state) do
    Focus.focused?(state.focus, :main) and
      match?({:agent, _, _, _}, Enum.at(state.sidebar.entries, state.sidebar.cursor))
  end

  # Maximum useful scroll depth for the agent pane = rows in the scrollback buffer.
  # Caps main_scroll so it never grows past what's actually available to display.
  defp agent_max_scroll(state) do
    case Map.get(state.agents.screens, state.selection.agent_id) do
      nil -> 0
      screen -> screen.scrollback_count
    end
  end

  # Maximum useful scroll for non-agent content panes (initiative, dir, file).
  # Computed from the content line count stored in cursor_info; falls back to 0
  # so the pane stays at the top when cursor_info is absent or of unknown type.
  # Tree mode has no cursor_info for file content; use a large value and let
  # the CodeBlock widget clamp to the actual file length when rendering.
  defp non_agent_max_scroll(%{active_tab: :tree}), do: 99_999

  defp non_agent_max_scroll(state) do
    {_, pane_h} = state.pane_size
    max(cursor_content_lines(state.cursor_info) - pane_h, 0)
  end

  defp cursor_content_lines(%{type: :context_file, lines: lines}), do: length(lines)

  defp cursor_content_lines(%{type: :context_file, content: content}),
    do: content |> String.split("\n") |> length()

  defp cursor_content_lines(%{type: :initiative, line_count: count}), do: count

  defp cursor_content_lines(%{type: :dir, commits: commits}), do: 8 + length(commits)

  defp cursor_content_lines(%{type: :context_dir, files: files}), do: 5 + length(files)

  defp cursor_content_lines(_), do: 0

  # Throttles scroll renders to at most one every 16 ms (~60 fps).
  # Crucially, the timer is only armed when no render is already pending —
  # resetting it on every event (debounce) would cause livelock during fast
  # scrolling: renders would never fire while the wheel is spinning.
  defp debounce_scroll(state) do
    new_refs =
      if is_nil(state.refs.scroll_render) do
        %{state.refs | scroll_render: Process.send_after(self(), :scroll_render, 16)}
      else
        state.refs
      end

    {:noreply, %{state | refs: new_refs}, [render?: false]}
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
      "#{f.(kb.start_orchestration)}:orchestrate  " <>
      "#{f.(kb.delete)}:delete  " <>
      "#{f.(kb.start_terminal)}:terminal  " <>
      "Tab:agent pane  " <>
      "#{f.(kb.diff_mode)}:diff  " <>
      "#{f.(kb.palette)}:palette  " <>
      "#{f.(kb.quit)}:quit"
  end

  defp build_temp_status(kb) do
    build_default_status(kb) <> "  P:promote"
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
      %{id: :tree_mode, label: "Tree View", hint: Keybindings.format(kb.tree_mode)},
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
      %{id: :start_agent, label: "Start Agent", hint: Keybindings.format(kb.start_agent)},
      %{
        id: :start_terminal,
        label: "Open Terminal Here",
        hint: Keybindings.format(kb.start_terminal)
      },
      %{
        id: :start_orchestration,
        label: "Start Orchestration",
        hint: Keybindings.format(kb.start_orchestration)
      },
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
      # Sidebar filter
      %{id: :filter_files, label: "Filter Files (Diff / Tree)", hint: "/"},
      # Other
      %{id: :shortcuts, label: "Keyboard Shortcuts", hint: "?"},
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

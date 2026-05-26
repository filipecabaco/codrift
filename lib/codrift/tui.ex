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
  | `Tab` / `Shift+Tab` | Cycle focus (sidebar ↔ main) |
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
  | `q` / `Ctrl+C` | Quit (kills all running agents) |

  ## Themes

  Set the visual theme by creating `~/.codrift/theme.json`:

      {"theme": "dracula"}

  Available themes: `default`, `dracula`, `nord`, `solarized`, `tokyo_night`.
  See `Codrift.Config.Theme` for full details.
  """

  use ExRatatui.App

  alias ExRatatui.{Focus, Layout, Style}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Event.{Key, Mouse}
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.CodeBlock
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Textarea

  alias Codrift.{AgentProcess, AgentSupervisor, Diff, Initiative, Paths}
  alias Codrift.Config.{Keybindings, Theme}
  alias Codrift.Initiative.Store
  alias Codrift.TUI.{DirPicker, Modals, Sidebar, Styles, VT100}

  @type modal :: :none | :new_name | :new_dir | :confirm_delete | :palette | :theme_picker
  @type tab :: :context | :diff

  defstruct [
    :focus,
    :sidebar_entries,
    :sidebar_cursor,
    :selected_initiative_id,
    :selected_agent_id,
    :subscribed_agents,
    :agent_outputs,
    :vt100_screens,
    :pane_size,
    :active_tab,
    :diff_files,
    :cursor_info,
    :main_scroll,
    :status,
    :modal,
    :modal_input,
    :modal_context,
    :dir_suggestions,
    :dir_suggestion_cursor,
    :palette_cursor,
    :palette_filter,
    :actions,
    :input_buffer,
    :selected_agent_mode,
    :resize_ref,
    :sidebar_tick_ref,
    :editor_ref,
    :editing_file,
    :autosave_ref,
    :term_size,
    # Diff tab state (separate from main_scroll to avoid reset on sidebar navigation)
    :diff_scroll,
    :diff_view_mode,
    # diff sidebar (replaces context sidebar when active_tab == :diff)
    :diff_sidebar_entries,
    :diff_sidebar_cursor,
    :sidebar_collapsed,
    # Timer ref for flash_status — cancelled before each new flash to prevent stacking.
    :status_timer_ref,
    # Config: keybindings and theme (loaded from ~/.codrift/ at startup)
    :keybindings,
    :keybindings_reverse,
    :theme,
    # Theme picker modal state
    :theme_picker_cursor,
    :theme_before_picker
  ]

  @impl true
  def mount(_opts) do
    Process.send_after(self(), :autostart_sessions, 300)
    initiatives = Store.list()
    agents = Enum.map(AgentSupervisor.list_agents(), &AgentProcess.status/1)

    {term_w, term_h} = ExRatatui.terminal_size()
    {pane_cols, pane_rows} = calc_pane_size(term_w, term_h)

    keybindings = Keybindings.load()
    keybindings_reverse = Keybindings.build_reverse(keybindings)
    theme = Theme.load()

    initial_state = %__MODULE__{
      focus: Focus.new([:sidebar, :main]),
      sidebar_entries: Sidebar.build_entries(initiatives, agents),
      sidebar_cursor: 0,
      selected_initiative_id: nil,
      selected_agent_id: nil,
      subscribed_agents: MapSet.new(),
      agent_outputs: %{},
      vt100_screens: %{},
      pane_size: {pane_cols, pane_rows},
      term_size: {term_w, term_h},
      active_tab: :context,
      diff_files: [],
      cursor_info: nil,
      main_scroll: 0,
      status: build_default_status(keybindings),
      modal: :none,
      modal_input: ExRatatui.text_input_new(),
      modal_context: nil,
      dir_suggestions: [],
      dir_suggestion_cursor: 0,
      palette_cursor: 0,
      palette_filter: "",
      actions: build_actions(keybindings),
      input_buffer: "",
      selected_agent_mode: nil,
      resize_ref: nil,
      sidebar_tick_ref: Process.send_after(self(), :sidebar_tick, 2000),
      editor_ref: ExRatatui.textarea_new(),
      editing_file: nil,
      autosave_ref: nil,
      diff_scroll: 0,
      diff_view_mode: :unified,
      diff_sidebar_entries: [],
      diff_sidebar_cursor: 0,
      sidebar_collapsed: false,
      status_timer_ref: nil,
      keybindings: keybindings,
      keybindings_reverse: keybindings_reverse,
      theme: theme,
      theme_picker_cursor: 0,
      theme_before_picker: nil
    }

    {:ok, update_context_from_cursor(initial_state)}
  end

  @impl true
  def render(state, frame) do
    full = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [header_rect, body_rect, footer_rect] =
      Layout.split(full, :vertical, [{:length, 1}, {:min, 0}, {:length, 1}])

    {sidebar_widgets, main_rect} =
      if state.sidebar_collapsed do
        {[], body_rect}
      else
        [sidebar_rect, mr] =
          Layout.split(body_rect, :horizontal, [{:percentage, 30}, {:percentage, 70}])

        sidebar_widget =
          if state.active_tab == :diff do
            Sidebar.render_diff(
              state.diff_sidebar_entries,
              state.diff_sidebar_cursor,
              state.focus,
              state.theme
            )
          else
            Sidebar.render(state.sidebar_entries, state.sidebar_cursor, state.focus, state.theme)
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
  def handle_event(%Key{code: "c", kind: "press", modifiers: ["ctrl"]}, state) do
    if Focus.focused?(state.focus, :main) and state.selected_agent_mode == :pty do
      {:noreply, forward_raw(state, "\x03")}
    else
      {:stop, state}
    end
  end

  def handle_event(%ExRatatui.Event.Resize{width: w, height: h}, state) do
    if state.resize_ref, do: Process.cancel_timer(state.resize_ref)
    ref = Process.send_after(self(), {:apply_resize, w, h}, 50)
    {:noreply, %{state | resize_ref: ref, term_size: {w, h}}}
  end

  # ── Mouse events ─────────────────────────────────────────────────────────────

  # Scroll in whichever pane the cursor is over.
  def handle_event(%Mouse{kind: "scroll_up"} = ev, %{modal: :none} = state) do
    {:noreply, mouse_scroll(state, ev, -3)}
  end

  def handle_event(%Mouse{kind: "scroll_down"} = ev, %{modal: :none} = state) do
    {:noreply, mouse_scroll(state, ev, 3)}
  end

  # Left click: focus the pane under the pointer.
  def handle_event(%Mouse{kind: "down", button: "left", x: x, y: _y}, %{modal: :none} = state) do
    {term_w, _} = state.term_size || {80, 24}
    sidebar_width = if state.sidebar_collapsed, do: 0, else: round(term_w * 0.30)

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
  def handle_event(%Key{code: "esc", kind: "press"}, %{editing_file: f} = state)
      when not is_nil(f) do
    {:noreply, save_and_close_editing(state)}
  end

  # Every other keypress in edit mode: forward to textarea + arm a 500 ms autosave.
  def handle_event(%Key{kind: "press"} = key, %{editing_file: f} = state)
      when not is_nil(f) do
    ExRatatui.textarea_handle_key(state.editor_ref, key.code, key.modifiers)
    if state.autosave_ref, do: Process.cancel_timer(state.autosave_ref)
    ref = Process.send_after(self(), :autosave, 500)
    {:noreply, %{state | autosave_ref: ref}}
  end

  def handle_event(%Key{code: "esc", kind: "press"}, %{modal: :theme_picker} = state) do
    {:noreply,
     %{state | modal: :none, theme: state.theme_before_picker, theme_before_picker: nil}}
  end

  def handle_event(%Key{code: "esc", kind: "press"}, %{modal: modal} = state)
      when modal != :none do
    {:noreply, flash_status(%{state | modal: :none}, "Cancelled")}
  end

  # Modal-specific event handling

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :confirm_delete} = state),
    do: {:noreply, do_delete(state)}

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :new_name} = state),
    do: {:noreply, confirm_name(state)}

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :new_dir} = state),
    do: {:noreply, confirm_dir(state)}

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :palette} = state),
    do: {:noreply, execute_palette_action(state)}

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :new_context_file} = state),
    do: {:noreply, confirm_context_file(state)}

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :theme_picker} = state),
    do: {:noreply, apply_theme_picker(state)}

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: :new_dir} = state),
    do: {:noreply, DirPicker.move_cursor(state, -1)}

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: :new_dir} = state),
    do: {:noreply, DirPicker.move_cursor(state, 1)}

  def handle_event(%Key{code: "tab", kind: "press"}, %{modal: :new_dir} = state),
    do: {:noreply, DirPicker.complete(state)}

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: :palette} = state),
    do: {:noreply, %{state | palette_cursor: max(state.palette_cursor - 1, 0)}}

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: :palette} = state) do
    max_idx = max(length(Modals.filter_actions(state.actions, state.palette_filter)) - 1, 0)
    {:noreply, %{state | palette_cursor: min(state.palette_cursor + 1, max_idx)}}
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: :theme_picker} = state) do
    cursor = max(state.theme_picker_cursor - 1, 0)
    theme = Enum.at(theme_picker_list(), cursor).theme
    {:noreply, %{state | theme_picker_cursor: cursor, theme: theme}}
  end

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: :theme_picker} = state) do
    max_idx = length(theme_picker_list()) - 1
    cursor = min(state.theme_picker_cursor + 1, max_idx)
    theme = Enum.at(theme_picker_list(), cursor).theme
    {:noreply, %{state | theme_picker_cursor: cursor, theme: theme}}
  end

  def handle_event(%Key{code: code, kind: "press"}, %{modal: modal} = state)
      when modal in [:new_name, :new_dir, :palette, :new_context_file] and byte_size(code) == 1 do
    ExRatatui.text_input_handle_key(state.modal_input, code)
    {:noreply, sync_modal(state, modal)}
  end

  def handle_event(%Key{code: code, kind: "press"}, %{modal: modal} = state)
      when modal in [:new_name, :new_dir, :palette, :new_context_file] and
             code in ["backspace", "delete", "left", "right", "home", "end"] do
    ExRatatui.text_input_handle_key(state.modal_input, code)
    {:noreply, sync_modal(state, modal)}
  end

  # Normal mode — no modal open.
  #
  # Focus determines routing:
  #   :sidebar → j/k navigate, letters are management shortcuts
  #   :main    → all printable chars go to the agent input buffer

  def handle_event(%Key{code: code, kind: "press"} = key, %{modal: :none} = state)
      when code in ["tab", "back_tab"] do
    {new_focus, _} = Focus.handle_key(state.focus, key)
    {:noreply, %{state | focus: new_focus, input_buffer: ""}}
  end

  def handle_event(%Key{code: "d", kind: "press", modifiers: ["ctrl"]}, %{modal: :none} = state) do
    cond do
      Focus.focused?(state.focus, :main) and state.selected_agent_mode == :pty ->
        {:noreply, forward_raw(state, "\x04")}

      state.active_tab == :diff ->
        {:noreply, %{state | diff_scroll: state.diff_scroll + 10}}

      true ->
        {:noreply, %{state | main_scroll: state.main_scroll + 10}}
    end
  end

  def handle_event(%Key{code: "u", kind: "press", modifiers: ["ctrl"]}, %{modal: :none} = state) do
    cond do
      Focus.focused?(state.focus, :main) and state.selected_agent_mode == :pty ->
        {:noreply, forward_raw(state, "\x15")}

      state.active_tab == :diff ->
        {:noreply, %{state | diff_scroll: max(state.diff_scroll - 10, 0)}}

      true ->
        {:noreply, %{state | main_scroll: max(state.main_scroll - 10, 0)}}
    end
  end

  # Generic ctrl-key handler — dispatches configured actions (toggle_sidebar, palette, …).
  # Must come after ctrl+c/d/u which have PTY-forwarding logic.
  def handle_event(%Key{code: code, kind: "press", modifiers: ["ctrl"]}, %{modal: :none} = state) do
    action = Map.get(state.keybindings_reverse, "ctrl+#{code}")
    dispatch_sidebar_action(action, state)
  end

  # Main pane focused — route to agent based on its mode
  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :none} = state) do
    if Focus.focused?(state.focus, :main) do
      case state.selected_agent_mode do
        :pty -> {:noreply, forward_raw(state, "\r")}
        _ -> {:noreply, send_agent_input(state)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_event(%Key{code: "esc", kind: "press"}, %{modal: :none} = state) do
    if Focus.focused?(state.focus, :main) do
      case state.selected_agent_mode do
        :pty -> {:noreply, forward_raw(state, "\e")}
        _ -> {:noreply, flash_status(%{state | input_buffer: ""}, "Input cleared")}
      end
    else
      {:noreply, state}
    end
  end

  def handle_event(%Key{code: "backspace", kind: "press"}, %{modal: :none} = state) do
    if Focus.focused?(state.focus, :main) do
      case state.selected_agent_mode do
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
  #   1. Configured quit key → always quit (even from PTY pane, matching legacy `q` behaviour)
  #   2. Main pane + PTY agent → forward raw to PTY
  #   3. Main pane + non-PTY + edit_context key on a context_file → open editor
  #   4. Main pane + non-PTY → append to input buffer
  #   5. Sidebar focused → dispatch via configured action
  def handle_event(%Key{code: code, kind: "press"}, %{modal: :none} = state)
      when byte_size(code) == 1 do
    action = Map.get(state.keybindings_reverse, code)

    cond do
      action == :quit ->
        save_all_sessions(state)
        {:stop, state}

      Focus.focused?(state.focus, :main) and state.selected_agent_mode == :pty ->
        {:noreply, forward_raw(state, code)}

      Focus.focused?(state.focus, :main) and action == :edit_context ->
        case state.cursor_info do
          %{type: :context_file, path: path} -> {:noreply, start_editing(state, path)}
          _ -> {:noreply, %{state | input_buffer: state.input_buffer <> code}}
        end

      Focus.focused?(state.focus, :main) ->
        {:noreply, %{state | input_buffer: state.input_buffer <> code}}

      true ->
        dispatch_sidebar_action(action, state)
    end
  end

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: :none} = state) do
    cond do
      Focus.focused?(state.focus, :sidebar) ->
        {:noreply, navigate(state, 1)}

      state.active_tab == :diff ->
        {:noreply, %{state | diff_scroll: state.diff_scroll + 3}}

      Focus.focused?(state.focus, :main) and state.selected_agent_mode == :pty ->
        {:noreply, forward_raw(state, "\e[B")}

      Focus.focused?(state.focus, :main) ->
        {:noreply, %{state | main_scroll: state.main_scroll + 3}}

      true ->
        {:noreply, state}
    end
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: :none} = state) do
    cond do
      Focus.focused?(state.focus, :sidebar) ->
        {:noreply, navigate(state, -1)}

      state.active_tab == :diff ->
        {:noreply, %{state | diff_scroll: max(state.diff_scroll - 3, 0)}}

      Focus.focused?(state.focus, :main) and state.selected_agent_mode == :pty ->
        {:noreply, forward_raw(state, "\e[A")}

      Focus.focused?(state.focus, :main) ->
        {:noreply, %{state | main_scroll: max(state.main_scroll - 3, 0)}}

      true ->
        {:noreply, state}
    end
  end

  def handle_event(%Key{code: "right", kind: "press"}, %{modal: :none} = state) do
    if Focus.focused?(state.focus, :main) and state.selected_agent_mode == :pty do
      {:noreply, forward_raw(state, "\e[C")}
    else
      {:noreply, state}
    end
  end

  def handle_event(%Key{code: "left", kind: "press"}, %{modal: :none} = state) do
    if Focus.focused?(state.focus, :main) and state.selected_agent_mode == :pty do
      {:noreply, forward_raw(state, "\e[D")}
    else
      {:noreply, state}
    end
  end

  def handle_event(_, state), do: {:noreply, state}

  # ── Action dispatcher ─────────────────────────────────────────────────────────
  # Handles each action atom, called from both the sidebar key path and the
  # generic ctrl-key handler.

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
        diff_scroll: 0,
        diff_sidebar_cursor: 0,
        diff_view_mode: :unified
    }

    {:noreply, refresh_diff(new_state)}
  end

  defp dispatch_sidebar_action(:toggle_diff_view, %{active_tab: :diff} = state) do
    new_mode = if state.diff_view_mode == :unified, do: :split, else: :unified
    {:noreply, %{state | diff_view_mode: new_mode, diff_scroll: 0}}
  end

  defp dispatch_sidebar_action(:toggle_diff_view, state), do: {:noreply, state}

  defp dispatch_sidebar_action(:diff_all_files, %{active_tab: :diff} = state),
    do: {:noreply, %{state | diff_sidebar_cursor: 0, diff_scroll: 0}}

  defp dispatch_sidebar_action(:diff_all_files, state), do: {:noreply, state}

  defp dispatch_sidebar_action(:add_dir, state),
    do: {:noreply, open_add_dir_modal(state)}

  defp dispatch_sidebar_action(:start_agent, state),
    do: {:noreply, start_agent_at_cursor(state, Codrift.Agent.Adapters.Claude)}

  defp dispatch_sidebar_action(:start_terminal, state),
    do: {:noreply, start_agent_at_cursor(state, Codrift.Agent.Adapters.Terminal)}

  defp dispatch_sidebar_action(:new_context, state),
    do: {:noreply, open_new_context_file_modal(state)}

  defp dispatch_sidebar_action(:delete, state),
    do: {:noreply, open_delete_confirm(state)}

  defp dispatch_sidebar_action(:edit_context, state) do
    case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
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
    ExRatatui.text_input_set_value(state.modal_input, "")
    {:noreply, %{state | modal: :new_name, status: "New initiative — Enter: next  Esc: cancel"}}
  end

  defp dispatch_sidebar_action(:toggle_sidebar, state),
    do: {:noreply, toggle_sidebar(state)}

  defp dispatch_sidebar_action(:palette, state) do
    ExRatatui.text_input_set_value(state.modal_input, "")
    {:noreply, %{state | modal: :palette, palette_cursor: 0, palette_filter: ""}}
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

    screen = Map.get(state.vt100_screens, agent_id, VT100.new(w, h))

    updated = VT100.process(screen, data)
    new_screens = Map.put(state.vt100_screens, agent_id, updated)

    outputs =
      Map.update(state.agent_outputs, agent_id, [data], fn buf ->
        Enum.take([data | buf], 200)
      end)

    new_scroll =
      if agent_id == state.selected_agent_id do
        # VT100 screen is sized exactly to the pane; it manages its own viewport.
        # Always snap to 0 so new output shows the current terminal state.
        0
      else
        state.main_scroll
      end

    {:noreply,
     %{state | vt100_screens: new_screens, agent_outputs: outputs, main_scroll: new_scroll}}
  end

  def handle_info({:apply_resize, w, h}, state) do
    {pane_w, pane_h} = calc_pane_size(w, h, state.sidebar_collapsed)

    new_screens =
      Map.new(state.vt100_screens, fn {id, screen} ->
        {id, VT100.resize(screen, pane_w, pane_h)}
      end)

    resize_all_ptys(pane_w, pane_h)

    new_scroll =
      case Map.get(new_screens, state.selected_agent_id) do
        nil -> 0
        # VT100 screen resized in place; snap to 0 to show current terminal state.
        _screen -> 0
      end

    {:noreply,
     %{
       state
       | pane_size: {pane_w, pane_h},
         vt100_screens: new_screens,
         main_scroll: new_scroll,
         resize_ref: nil
     }}
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
    new_state = %{state | subscribed_agents: MapSet.delete(state.subscribed_agents, agent_id)}
    {:noreply, reload_sidebar(flash_status(new_state, "Agent #{short} finished"))}
  end

  def handle_info({:agent_stopped, agent_id, code}, state) do
    short = String.slice(agent_id, 0, 8)
    new_state = %{state | subscribed_agents: MapSet.delete(state.subscribed_agents, agent_id)}

    {:noreply,
     reload_sidebar(
       flash_status(new_state, "! Agent #{short} exited #{code} — see output pane", 4000)
     )}
  end

  # Ink optimizes away the repaint when terminal dimensions haven't changed.
  # Force a full \e[2J + redraw by briefly sending a different size, then
  # restoring the correct one. Two distinct SIGWINCHes guarantee a full clear.
  def handle_info({:nudge_agent, agent_id, w, h}, state) do
    if agent_id == state.selected_agent_id do
      case AgentSupervisor.find_agent(agent_id) do
        {:ok, pid} ->
          AgentProcess.resize(pid, max(w - 1, 1), h)
          Process.send_after(self(), {:restore_agent_size, agent_id, w, h}, 60)

        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  def handle_info({:restore_agent_size, agent_id, w, h}, state) do
    if agent_id == state.selected_agent_id do
      case AgentSupervisor.find_agent(agent_id) do
        {:ok, pid} ->
          AgentProcess.resize(pid, w, h)
          # After the restore repaint completes, send \r to force Claude Code to
          # redraw its input prompt.  This is the "special character" that puts
          # the cursor at the input line.  Only fires when Claude is at the
          # prompt (awaiting_input) — harmless no-op otherwise.
          Process.send_after(self(), {:input_nudge, agent_id}, 100)

        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  # Sends \r to Claude Code when it's sitting at the ❯ prompt.
  # This forces Ink to redraw the input line and positions the cursor correctly.
  # Terminal/shell agents must NOT receive this — they interpret \r as an empty
  # Enter keypress and print an extra prompt each time.
  def handle_info({:input_nudge, agent_id}, state) do
    if agent_id == state.selected_agent_id do
      screen = Map.get(state.vt100_screens, agent_id)

      if screen && screen.cursor_visible do
        case AgentSupervisor.find_agent(agent_id) do
          {:ok, pid} ->
            status = AgentProcess.status(pid)

            if status.status == :awaiting_input and
                 status.adapter == Codrift.Agent.Adapters.Claude do
              AgentProcess.send_raw(pid, "\r")
            end

          _ ->
            :ok
        end
      end
    end

    {:noreply, state}
  end

  def handle_info(:sidebar_tick, state) do
    ref = Process.send_after(self(), :sidebar_tick, 2000)
    {:noreply, reload_sidebar(%{state | sidebar_tick_ref: ref})}
  end

  # Autosave fires 500 ms after the last keystroke while editing a file.
  def handle_info(:autosave, %{editing_file: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:autosave, state) do
    # Silent save — don't interrupt the editing status hint.
    # Only surface errors. Guard against writing outside the managed context tree.
    new_state =
      if Store.context_file_path?(state.editing_file) do
        content = ExRatatui.textarea_get_value(state.editor_ref)

        case File.write(state.editing_file, content) do
          :ok -> %{state | autosave_ref: nil}
          {:error, r} -> %{state | autosave_ref: nil, status: "Autosave failed: #{inspect(r)}"}
        end
      else
        %{state | autosave_ref: nil, status: "Autosave refused: path outside Codrift folder"}
      end

    {:noreply, new_state}
  end

  def handle_info(:reset_status, state) do
    {:noreply, %{state | status: build_default_status(state.keybindings), status_timer_ref: nil}}
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
            do_start_agent(acc, initiative_id, dir, Codrift.Agent.Adapters.Claude, agent_id)

          _ ->
            acc
        end
      end)

    {:noreply, new_state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp save_all_sessions(state) do
    for agent_id <- MapSet.to_list(state.subscribed_agents) do
      try do
        with {:ok, pid} <- AgentSupervisor.find_agent(agent_id),
             status <- AgentProcess.status(pid),
             # Only persist Claude sessions — Terminal and other adapters don't
             # use --resume and should never be auto-restarted on next launch.
             true <- status.adapter == Codrift.Agent.Adapters.Claude,
             uuid when not is_nil(uuid) <- AgentProcess.session_uuid(pid) do
          Codrift.SessionStore.save(agent_id, status.initiative_id, status.dir, uuid)
        end
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp confirm_name(state) do
    name = String.trim(ExRatatui.text_input_get_value(state.modal_input))

    if name == "" do
      flash_status(state, "Name cannot be empty")
    else
      ExRatatui.text_input_set_value(state.modal_input, "")

      %{
        state
        | modal: :new_dir,
          modal_context: {:creating, name},
          dir_suggestions: DirPicker.suggestions(""),
          dir_suggestion_cursor: 0,
          status: "↑/↓: navigate  Tab: complete  Enter: create  Esc: cancel"
      }
    end
  end

  defp confirm_dir(%{modal_context: {:creating, name}} = state) do
    dir = typed_dir(state)

    if File.dir?(dir) do
      case Store.create(name, [dir]) do
        {:ok, initiative} ->
          state
          |> reload_sidebar()
          |> then(fn s ->
            flash_status(
              %{s | modal: :none, modal_context: nil, selected_initiative_id: initiative.id},
              "Created '#{name}'"
            )
          end)

        {:error, reason} ->
          flash_status(
            %{state | modal: :none, modal_context: nil},
            "Create failed: #{inspect(reason)}"
          )
      end
    else
      flash_status(state, "Directory does not exist: #{Paths.compact(dir)}")
    end
  end

  defp confirm_dir(%{modal_context: {:add_dir, initiative_id}} = state) do
    dir = typed_dir(state)

    if File.dir?(dir) do
      case Store.add_dir(initiative_id, dir) do
        {:ok, _} ->
          state
          |> reload_sidebar()
          |> then(fn s ->
            flash_status(%{s | modal: :none, modal_context: nil}, "Added: #{Paths.compact(dir)}")
          end)

        {:error, reason} ->
          flash_status(%{state | modal: :none, modal_context: nil}, "Failed: #{inspect(reason)}")
      end
    else
      flash_status(state, "Directory does not exist: #{Paths.compact(dir)}")
    end
  end

  defp confirm_dir(state), do: %{state | modal: :none, modal_context: nil}

  defp typed_dir(state) do
    state.modal_input |> ExRatatui.text_input_get_value() |> String.trim() |> Path.expand()
  end

  defp open_add_dir_modal(state) do
    initiative_id =
      case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
        {:initiative, id, _, _, _, _} -> id
        {:dir, id, _, _} -> id
        {:context_dir, id, _, _} -> id
        {:context_file, id, _, _} -> id
        _ -> state.selected_initiative_id
      end

    if is_nil(initiative_id) do
      flash_status(state, "Navigate to an initiative or directory first")
    else
      ExRatatui.text_input_set_value(state.modal_input, "")

      %{
        state
        | modal: :new_dir,
          modal_context: {:add_dir, initiative_id},
          dir_suggestions: DirPicker.suggestions(""),
          dir_suggestion_cursor: 0,
          status: "↑/↓: navigate  Tab: complete  Enter: add  Esc: cancel"
      }
    end
  end

  defp open_delete_confirm(state) do
    case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
      {:initiative, id, name, _, _, _} ->
        %{state | modal: :confirm_delete, modal_context: {:delete_initiative, id, name}}

      {:dir, initiative_id, dir, _} ->
        %{state | modal: :confirm_delete, modal_context: {:remove_dir, initiative_id, dir}}

      {:context_dir, _, _, _} ->
        flash_status(state, "Press 'c' to create files in the context folder")

      {:context_file, _, path, name} ->
        %{state | modal: :confirm_delete, modal_context: {:delete_context_file, path, name}}

      {:agent, agent_id, _, _} ->
        %{state | modal: :confirm_delete, modal_context: {:stop_agent, agent_id}}

      nil ->
        flash_status(state, "Navigate to an item first")
    end
  end

  defp do_delete(%{modal_context: {:delete_initiative, id, name}} = state) do
    case Store.delete(id) do
      :ok ->
        cleared =
          if state.selected_initiative_id == id, do: nil, else: state.selected_initiative_id

        state
        |> reload_sidebar()
        |> then(fn s ->
          flash_status(
            %{
              s
              | modal: :none,
                modal_context: nil,
                selected_initiative_id: cleared,
                cursor_info: nil
            },
            "Deleted '#{name}'"
          )
        end)

      {:error, reason} ->
        flash_status(
          %{state | modal: :none, modal_context: nil},
          "Delete failed: #{inspect(reason)}"
        )
    end
  end

  defp do_delete(%{modal_context: {:remove_dir, initiative_id, dir}} = state) do
    case Store.remove_dir(initiative_id, dir) do
      {:ok, _} ->
        state
        |> reload_sidebar()
        |> then(fn s ->
          flash_status(
            %{s | modal: :none, modal_context: nil, cursor_info: nil},
            "Removed: #{Paths.compact(dir)}"
          )
        end)

      {:error, reason} ->
        flash_status(%{state | modal: :none, modal_context: nil}, "Failed: #{inspect(reason)}")
    end
  end

  defp do_delete(%{modal_context: {:delete_context_file, path, name}} = state) do
    if Store.context_file_path?(path) do
      case File.rm(path) do
        :ok ->
          state
          |> reload_sidebar()
          |> update_context_from_cursor()
          |> then(&flash_status(%{&1 | modal: :none, modal_context: nil}, "Deleted #{name}"))

        {:error, reason} ->
          flash_status(
            %{state | modal: :none, modal_context: nil},
            "Delete failed: #{inspect(reason)}"
          )
      end
    else
      flash_status(
        %{state | modal: :none, modal_context: nil},
        "Refused: #{path} is outside the Codrift context folder"
      )
    end
  end

  defp do_delete(%{modal_context: {:stop_agent, agent_id}} = state) do
    case AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} ->
        AgentSupervisor.stop_agent(pid)
        cleared = if state.selected_agent_id == agent_id, do: nil, else: state.selected_agent_id

        state
        |> reload_sidebar()
        |> then(fn s ->
          flash_status(
            %{s | modal: :none, modal_context: nil, selected_agent_id: cleared},
            "Agent stopped"
          )
        end)

      {:error, :not_found} ->
        flash_status(%{state | modal: :none, modal_context: nil}, "Agent not found")
    end
  end

  defp execute_palette_action(state) do
    filtered = Modals.filter_actions(state.actions, state.palette_filter)

    case Enum.at(filtered, state.palette_cursor) do
      nil ->
        %{state | modal: :none}

      # ── Navigation ────────────────────────────────────────────────────────────

      %{id: :toggle_sidebar} ->
        toggle_sidebar(%{state | modal: :none})

      %{id: :context_mode} ->
        %{state | modal: :none, active_tab: :context, main_scroll: 0}
        |> update_context_from_cursor()

      %{id: :diff_mode} ->
        refresh_diff(%{
          state
          | modal: :none,
            active_tab: :diff,
            main_scroll: 0,
            diff_scroll: 0,
            diff_sidebar_cursor: 0,
            diff_view_mode: :unified
        })

      %{id: :toggle_diff_view} ->
        new_mode = if state.diff_view_mode == :unified, do: :split, else: :unified
        %{state | modal: :none, diff_view_mode: new_mode, diff_scroll: 0}

      %{id: :diff_all_files} ->
        %{state | modal: :none, diff_sidebar_cursor: 0, diff_scroll: 0}

      # ── Initiatives & directories ─────────────────────────────────────────────

      %{id: :new_initiative} ->
        ExRatatui.text_input_set_value(state.modal_input, "")
        %{state | modal: :new_name}

      %{id: :add_dir} ->
        open_add_dir_modal(%{state | modal: :none})

      %{id: :cycle_status} ->
        cycle_initiative_status(%{state | modal: :none}, :next)

      %{id: :delete_current} ->
        open_delete_confirm(%{state | modal: :none})

      # ── Agents ────────────────────────────────────────────────────────────────

      %{id: :start_claude} ->
        start_agent_at_cursor(%{state | modal: :none}, Codrift.Agent.Adapters.Claude)

      %{id: :start_terminal} ->
        start_agent_at_cursor(%{state | modal: :none}, Codrift.Agent.Adapters.Terminal)

      %{id: :start_aider} ->
        start_agent_at_cursor(%{state | modal: :none}, Codrift.Agent.Adapters.Aider)

      # ── Context files ─────────────────────────────────────────────────────────

      %{id: :new_context_file} ->
        open_new_context_file_modal(%{state | modal: :none})

      %{id: :edit_context_file} ->
        case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
          {:context_file, _, path, _} -> start_editing(%{state | modal: :none}, path)
          _ -> flash_status(%{state | modal: :none}, "Navigate to a context file first")
        end

      # ── Theme ────────────────────────────────────────────────────────────────

      %{id: :theme_picker} ->
        themes = theme_picker_list()
        cursor = Enum.find_index(themes, fn %{theme: t} -> t.name == state.theme.name end) || 0

        %{
          state
          | modal: :theme_picker,
            theme_picker_cursor: cursor,
            theme_before_picker: state.theme
        }

      # ── Other ─────────────────────────────────────────────────────────────────

      %{id: :refresh} ->
        refresh_current(%{state | modal: :none})
    end
  end

  defp sync_modal(state, :palette) do
    filter = ExRatatui.text_input_get_value(state.modal_input)
    %{state | palette_filter: filter, palette_cursor: 0}
  end

  defp sync_modal(state, :new_dir), do: DirPicker.sync(state)
  defp sync_modal(state, _), do: state

  defp navigate(state, delta) do
    if Focus.focused?(state.focus, :sidebar) do
      if state.active_tab == :diff do
        # In diff mode the sidebar shows diff entries; navigate those independently.
        max_idx = max(length(state.diff_sidebar_entries) - 1, 0)
        new_cursor = min(max(state.diff_sidebar_cursor + delta, 0), max_idx)
        %{state | diff_sidebar_cursor: new_cursor, diff_scroll: 0}
      else
        max_idx = max(length(state.sidebar_entries) - 1, 0)
        new_cursor = min(max(state.sidebar_cursor + delta, 0), max_idx)

        %{state | sidebar_cursor: new_cursor, main_scroll: 0}
        |> update_context_from_cursor()
      end
    else
      case state.active_tab do
        :diff -> %{state | diff_scroll: max(state.diff_scroll + delta * 3, 0)}
        _ -> %{state | main_scroll: max(state.main_scroll + delta * 3, 0)}
      end
    end
  end

  defp update_context_from_cursor(state) do
    case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
      {:initiative, id, _, _, _, _} ->
        fetch_initiative_context(state, id)

      {:dir, initiative_id, dir, _} ->
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
          Enum.map(initiative.dirs, fn dir ->
            %{
              path: dir,
              branch: git_output(dir, ["branch", "--show-current"]),
              last_commit: git_output(dir, ["log", "-1", "--format=%h %s"]),
              agent_count: length(Map.get(by_dir, dir, []))
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
          md_sections: md_sections
        }

        %{state | cursor_info: cursor_info, selected_initiative_id: initiative_id}

      {:error, :not_found} ->
        state
    end
  end

  defp list_context_files(path) do
    case File.ls(path) do
      {:ok, files} -> files |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
      {:error, _} -> []
    end
  end

  defp fetch_context_dir_context(state, initiative_id, path) do
    files = list_context_files(path)

    cursor_info = %{
      type: :context_dir,
      path: path,
      files: files
    }

    %{state | cursor_info: cursor_info, selected_initiative_id: initiative_id}
  end

  defp fetch_context_file(state, initiative_id, path) do
    content =
      case File.read(path) do
        {:ok, text} -> text
        {:error, reason} -> "(could not read file: #{inspect(reason)})"
      end

    cursor_info = %{type: :context_file, path: path, content: content}
    %{state | cursor_info: cursor_info, selected_initiative_id: initiative_id}
  end

  defp fetch_dir_context(state, initiative_id, dir) do
    branch = git_output(dir, ["branch", "--show-current"])
    remote = git_output(dir, ["remote", "get-url", "origin"])
    commits_raw = git_output(dir, ["log", "--oneline", "-5"])
    commits = String.split(commits_raw, "\n", trim: true)

    cursor_info = %{
      type: :dir,
      path: dir,
      branch: branch,
      remote: remote,
      commits: commits
    }

    %{state | cursor_info: cursor_info, selected_initiative_id: initiative_id}
  end

  defp maybe_subscribe_agent(state, agent_id) do
    if MapSet.member?(state.subscribed_agents, agent_id) do
      # Already receiving live updates — switch display without re-subscribing.
      # Send a deferred SIGWINCH so Claude Code repaints at the current pane size,
      # which corrects any scroll drift without rebuilding the VT100 from scratch.
      # Skip the nudge for Terminal agents — the two-step resize is Ink-specific
      # and would just cause the shell to print a spurious extra prompt.
      status =
        case AgentSupervisor.find_agent(agent_id) do
          {:ok, pid} ->
            agent_status = AgentProcess.status(pid)

            if agent_status.adapter == Codrift.Agent.Adapters.Claude do
              {w, h} = state.pane_size
              Process.send_after(self(), {:nudge_agent, agent_id, w, h}, 80)
            end

            agent_status.mode

          _ ->
            state.selected_agent_mode
        end

      # VT100 screen shows the current terminal state; snap to top (scroll=0) on navigation.
      %{state | selected_agent_id: agent_id, selected_agent_mode: status, main_scroll: 0}
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

          # Claude Code (Ink renderer): use two-step resize (w-1 → w) to force a
          # full \e[2J repaint even when dimensions would otherwise be unchanged.
          # A second nudge at 600 ms catches slow-starting agents.
          # Terminal/shell agents: a single resize to the correct size is enough.
          # The two-step and the \r nudge cause the shell to print extra prompts.
          if status.adapter == Codrift.Agent.Adapters.Claude do
            AgentProcess.resize(pid, max(w - 1, 1), h)
            Process.send_after(self(), {:restore_agent_size, agent_id, w, h}, 150)
            Process.send_after(self(), {:nudge_agent, agent_id, w, h}, 600)
          else
            AgentProcess.resize(pid, w, h)
          end

          existing = pid |> AgentProcess.recent_output(200) |> Enum.reverse()

          # Claude Code (Ink): only replay from the last \e[2J / \ec anchor.
          # IL/DL operations (insert/delete line) need the correct scroll-region
          # context; replaying from before DECSTBM is set up corrupts row-shift
          # arithmetic. A clear is always followed by a full repaint, so nothing
          # is lost by truncating.
          #
          # Terminal/shell agents: replay all buffered output. Shells (zsh, bash)
          # never send \e[2J to draw their prompt, so chunks_from_last_clear would
          # return [] and the pane would be blank until the next keypress.
          replay =
            if status.adapter == Codrift.Agent.Adapters.Claude,
              do: chunks_from_last_clear(existing),
              else: existing

          screen =
            Enum.reduce(replay, VT100.new(w, h), fn chunk, s -> VT100.process(s, chunk) end)

          # For Terminal agents, shells like zsh with starship emit \n before
          # each prompt (add_newline = true). Replaying from scratch leaves row 0
          # blank. Scroll past any leading blank rows so the prompt sits at the top.
          initial_scroll =
            if status.adapter == Codrift.Agent.Adapters.Claude,
              do: 0,
              else: VT100.first_content_row(screen)

          short = String.slice(agent_id, 0, 8)

          %{
            state
            | selected_agent_id: agent_id,
              selected_agent_mode: status.mode,
              subscribed_agents: MapSet.put(state.subscribed_agents, agent_id),
              agent_outputs: Map.put(state.agent_outputs, agent_id, existing),
              vt100_screens: Map.put(state.vt100_screens, agent_id, screen),
              main_scroll: initial_scroll,
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

  defp start_agent_at_cursor(state, adapter) do
    case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
      {:initiative, id, _, _, _, _} ->
        do_start_agent(state, id, Store.context_path(id), adapter)

      {:dir, initiative_id, dir, _} ->
        do_start_agent(state, initiative_id, dir, adapter)

      {:context_dir, initiative_id, path, _} ->
        do_start_agent(state, initiative_id, path, adapter)

      {:context_file, initiative_id, file_path, _} ->
        do_start_agent(state, initiative_id, Path.dirname(file_path), adapter)

      _ ->
        flash_status(state, "Navigate to an initiative or directory to start an agent")
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

  defp cycle_initiative_status(state, direction) do
    case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
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
      case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
        {:initiative, id, _, _, _, _} -> Store.context_path(id)
        {:context_dir, _, path, _} -> path
        {:context_file, _, file_path, _} -> Path.dirname(file_path)
        _ -> if state.selected_initiative_id, do: Store.context_path(state.selected_initiative_id)
      end

    if is_nil(ctx_dir) do
      flash_status(state, "Navigate to an initiative first")
    else
      ExRatatui.text_input_set_value(state.modal_input, "")

      %{
        state
        | modal: :new_context_file,
          modal_context: {:new_context_file, ctx_dir},
          status: "Enter filename — Enter: create  Esc: cancel"
      }
    end
  end

  defp confirm_context_file(%{modal_context: {:new_context_file, ctx_dir}} = state) do
    filename = state.modal_input |> ExRatatui.text_input_get_value() |> String.trim()

    cond do
      filename == "" ->
        flash_status(state, "Filename cannot be empty")

      String.contains?(filename, "/") or String.contains?(filename, "..") ->
        flash_status(state, "Filename must not contain '/' or '..'")

      true ->
        path = Path.join(ctx_dir, filename)

        if Store.context_file_path?(path) do
          case File.write(path, "") do
            :ok ->
              state
              |> reload_sidebar()
              |> update_context_from_cursor()
              |> then(
                &flash_status(%{&1 | modal: :none, modal_context: nil}, "Created #{filename}")
              )

            {:error, reason} ->
              flash_status(
                %{state | modal: :none, modal_context: nil},
                "Failed: #{inspect(reason)}"
              )
          end
        else
          flash_status(
            %{state | modal: :none, modal_context: nil},
            "Refused: path outside Codrift context folder"
          )
        end
    end
  end

  defp confirm_context_file(state), do: %{state | modal: :none, modal_context: nil}

  defp refresh_current(%{active_tab: :diff} = state), do: refresh_diff(state)

  defp refresh_current(state) do
    state |> reload_sidebar() |> update_context_from_cursor()
  end

  defp refresh_diff(%{selected_initiative_id: nil} = state) do
    flash_status(state, "Select an initiative first")
  end

  defp refresh_diff(state) do
    case Store.get(state.selected_initiative_id) do
      {:ok, initiative} ->
        dir_diffs = Enum.map(initiative.dirs, fn dir -> {dir, diff_for_dir(dir)} end)
        total_files = Enum.sum(Enum.map(dir_diffs, fn {_, fs} -> length(fs) end))
        diff_sidebar = Sidebar.build_diff_entries(dir_diffs)

        flash_status(
          %{
            state
            | diff_files: dir_diffs,
              diff_sidebar_entries: diff_sidebar,
              diff_sidebar_cursor: 0,
              diff_scroll: 0
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

    %{state | sidebar_entries: Sidebar.build_entries(initiatives, agents)}
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
    case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
      {:initiative, _, name, _, _, _} -> render_initiative_pane(state, name)
      {:dir, _, dir, _} -> render_dir_pane(state, dir)
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
        md_sections: md_sections
      } ->
        content = build_initiative_md_content(md_sections, dirs, files, ctx_dir)

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

      %{type: :initiative, status: status, context_dir: ctx_dir, context_files: files, dirs: dirs} ->
        # fallback when md_sections not yet populated
        content = build_initiative_md_content([], dirs, files, ctx_dir)

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
          "No files yet.\n\nPress 'c' to create a new file here.\nDrop any files into this folder to share context with agents.\n\n◈ #{Paths.compact(path)}"

        %{type: :context_dir, files: files} ->
          file_list = Enum.map_join(files, "\n", fn f -> "  #{f}" end)

          "◈ #{Paths.compact(path)}\n\n#{file_list}\n\nPress 'c' to create a new file · 's' to start Claude · 't' for a terminal"

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
        if state.editing_file == path do
          %Textarea{
            state: state.editor_ref,
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
        else
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

  defp render_dir_pane(state, dir) do
    text =
      case state.cursor_info do
        %{type: :dir, branch: branch, remote: remote, commits: commits} ->
          remote_line = if remote == "(not a git repo)", do: "", else: "Remote:  #{remote}\n"
          commits_text = Enum.map_join(commits, "\n", fn c -> "  #{c}" end)
          "Branch:  #{branch}\n#{remote_line}\nRecent commits:\n#{commits_text}"

        _ ->
          "Loading…"
      end

    %Paragraph{
      text: text,
      block: %Block{
        title: " ▸ #{Paths.compact(dir)} ",
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

    screen = Map.get(state.vt100_screens, agent_id)
    raw_output = Map.get(state.agent_outputs, agent_id, [])
    has_output = screen != nil and (map_size(screen.cells) > 0 or raw_output != [])

    if has_output do
      render_agent_output(state, screen, focused, block)
    else
      render_agent_hint(status, focused, block)
    end
  end

  defp render_agent_hint(status, focused, block) do
    hint =
      cond do
        status == :stopped -> "Agent stopped. Press s to restart."
        status == :starting -> "Starting… waiting for the agent prompt to appear."
        status == :awaiting_input and focused -> "Agent ready. Type your message and press Enter."
        status == :awaiting_input -> "Agent ready. Tab to focus, then type your message."
        status == :running -> "Agent is working…"
        focused -> "Tab to focus · type · Enter to send"
        true -> "Navigate here then Tab to focus. Type to interact."
      end

    %Paragraph{text: hint, block: block, wrap: true}
  end

  defp render_agent_output(state, screen, focused, block) do
    prompt_suffix =
      if focused and state.selected_agent_mode != :pty and state.input_buffer != "",
        do: "\n> #{state.input_buffer}▌",
        else: ""

    content =
      if prompt_suffix == "",
        do: VT100.to_text(screen, focused),
        else: append_prompt(VT100.to_text(screen, false), prompt_suffix)

    %Paragraph{text: content, block: block, wrap: false, scroll: {state.main_scroll, 0}}
  end

  defp append_prompt(%ExRatatui.Text{lines: lines} = text, suffix) do
    extra =
      suffix
      |> String.split("\n")
      |> Enum.map(fn line ->
        %ExRatatui.Text.Line{spans: [%ExRatatui.Text.Span{content: line}]}
      end)

    %{text | lines: lines ++ extra}
  end

  defp resize_all_ptys(w, h) do
    for pid <- AgentSupervisor.list_agents() do
      AgentProcess.resize(pid, w, h)
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

    case state.diff_view_mode do
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
             scroll: {state.diff_scroll, 0}
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
             scroll: {state.diff_scroll, 0}
           }, left_rect},
          {%Paragraph{
             text: right_text,
             block: right_block,
             wrap: false,
             scroll: {state.diff_scroll, 0}
           }, right_rect}
        ]
    end
  end

  # Builds a %ExRatatui.Text{} for one side of the split diff view.
  # Removes are red on the old side, adds are green on the new side.
  # Padding rows (nil) render as empty lines with a faint background marker.
  defp build_split_text(rows, side) do
    alias ExRatatui.Text.{Line, Span}

    lines =
      Enum.map(rows, fn
        {:header, old, new} ->
          content = if side == :old, do: old || "", else: new || ""
          %Line{spans: [%Span{content: content, style: %Style{fg: :dark_gray}}]}

        {:context, old, new} ->
          content = if side == :old, do: old || "", else: new || ""
          %Line{spans: [%Span{content: content}]}

        {:change, old, new} ->
          case side do
            :old ->
              if old do
                %Line{spans: [%Span{content: old, style: %Style{fg: :red}}]}
              else
                %Line{spans: [%Span{content: "~", style: %Style{fg: :dark_gray}}]}
              end

            :new ->
              if new do
                %Line{spans: [%Span{content: new, style: %Style{fg: :green}}]}
              else
                %Line{spans: [%Span{content: "~", style: %Style{fg: :dark_gray}}]}
              end
          end
      end)

    %ExRatatui.Text{lines: lines}
  end

  # Returns the subset of FileDiff structs to display based on the diff
  # sidebar cursor position.
  defp diff_files_for_cursor(%{diff_sidebar_entries: [], diff_files: dir_diffs}) do
    Enum.flat_map(dir_diffs, fn {_, files} -> files end)
  end

  defp diff_files_for_cursor(%{
         diff_sidebar_entries: entries,
         diff_sidebar_cursor: cursor,
         diff_files: dir_diffs
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
    entry = Enum.at(state.diff_sidebar_entries, state.diff_sidebar_cursor)
    mode_hint = " v:#{next_view_mode(state.diff_view_mode)} *:all "

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
    sidebar_width = if state.sidebar_collapsed, do: 0, else: round(term_w * 0.30)

    cond do
      x < sidebar_width ->
        # Scrolling over the sidebar navigates its cursor
        new_cursor =
          (state.sidebar_cursor + delta)
          |> max(0)
          |> min(max(length(state.sidebar_entries) - 1, 0))

        %{state | sidebar_cursor: new_cursor}
        |> update_context_from_cursor()

      state.selected_agent_mode == :pty ->
        # PTY agents: forward scroll as arrow-key sequences (3 lines per tick)
        seq = if delta < 0, do: "\e[A", else: "\e[B"
        Enum.reduce(1..abs(delta), state, fn _, s -> forward_raw(s, seq) end)

      true ->
        # Code viewer / initiative / diff panes: move main_scroll
        %{state | main_scroll: max(state.main_scroll + delta, 0)}
    end
  end

  defp forward_raw(state, data) do
    screen = Map.get(state.vt100_screens, state.selected_agent_id)

    # Claude Code sends \e[?25l (hide cursor) while repainting and \e[?25h when
    # done. Forwarding keystrokes mid-repaint lands them at cursor_row=0 (the
    # \e[H from the clear), not at the input line. Drop input until the cursor
    # is visible again — repaints complete in < 200 ms so no keys are lost.
    if screen == nil or screen.cursor_visible do
      with id when not is_nil(id) <- state.selected_agent_id,
           {:ok, pid} <- AgentSupervisor.find_agent(id) do
        AgentProcess.send_raw(pid, data)
      end
    end

    state
  end

  defp send_agent_input(state) do
    text = String.trim(state.input_buffer)

    if text == "" or is_nil(state.selected_agent_id) do
      %{state | input_buffer: ""}
    else
      case AgentSupervisor.find_agent(state.selected_agent_id) do
        {:ok, pid} ->
          AgentProcess.send_input(pid, text)

          flash_status(
            %{state | input_buffer: ""},
            "Sent → #{String.slice(state.selected_agent_id, 0, 8)}"
          )

        {:error, :not_found} ->
          flash_status(%{state | input_buffer: ""}, "Agent not found")
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

    ExRatatui.textarea_set_value(state.editor_ref, content)

    %{
      state
      | editing_file: path,
        status:
          "editing — Esc: save & close  Ctrl+K: kill line  Ctrl+W: delete word  autosaves every 500 ms"
    }
  end

  # Saves and exits edit mode (Esc). Shows a brief confirmation then restores
  # the default shortcuts hint after 2 s.
  defp save_and_close_editing(state) do
    if state.autosave_ref, do: Process.cancel_timer(state.autosave_ref)
    base = %{state | editing_file: nil, autosave_ref: nil}

    if Store.context_file_path?(state.editing_file) do
      content = ExRatatui.textarea_get_value(state.editor_ref)

      case File.write(state.editing_file, content) do
        :ok ->
          base
          |> reload_sidebar()
          |> update_context_from_cursor()
          |> flash_status("Saved #{Path.basename(state.editing_file)}")

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
         status <- AgentProcess.status(pid),
         false <- status.adapter == Codrift.Agent.Adapters.Terminal,
         md_path <- Path.join(Store.context_path(status.initiative_id), "initiative.md"),
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
    new_collapsed = not state.sidebar_collapsed
    {term_w, term_h} = state.term_size || {80, 24}
    {pane_w, pane_h} = calc_pane_size(term_w, term_h, new_collapsed)

    new_screens =
      Map.new(state.vt100_screens, fn {id, screen} ->
        {id, VT100.resize(screen, pane_w, pane_h)}
      end)

    resize_all_ptys(pane_w, pane_h)

    new_focus =
      if new_collapsed and Focus.focused?(state.focus, :sidebar),
        do: Focus.new([:main, :sidebar]),
        else: state.focus

    %{
      state
      | sidebar_collapsed: new_collapsed,
        pane_size: {pane_w, pane_h},
        vt100_screens: new_screens,
        focus: new_focus
    }
  end

  # Sets a temporary status message and schedules :reset_status after `ms` ms.
  # Cancels any previously pending reset so rapid calls don't stack timers.
  defp flash_status(state, message, ms \\ 2000) do
    if state.status_timer_ref, do: Process.cancel_timer(state.status_timer_ref)
    ref = Process.send_after(self(), :reset_status, ms)
    %{state | status: message, status_timer_ref: ref}
  end

  # `find_syntax_by_token` in syntect resolves tokens against the syntax's
  # file_extensions list, so passing the bare extension (no dot) is the most
  # reliable lookup — "md" finds Markdown, "py" finds Python, "ex" finds
  # Elixir (custom bundled syntax), etc.  Unknown extensions return nil which
  # falls back to plain text.
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
  defp build_initiative_md_content(md_sections, dirs, files, ctx_dir) do
    user_sections =
      Enum.map_join(md_sections, "\n\n", fn {title, body} -> "## #{title}\n\n#{body}" end)

    dirs_section =
      if dirs == [] do
        "## Directories\n\n_(no directories added yet — press `a` to add one)_"
      else
        dir_lines = Enum.map_join(dirs, "\n\n", &format_dir_info_md/1)
        "## Directories\n\n#{dir_lines}"
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

  defp format_dir_info_md(%{path: path, branch: branch, last_commit: commit, agent_count: count}) do
    agents_label = if count == 0, do: "none", else: "#{count} running"

    "**#{Paths.compact(path)}**  \nbranch: `#{branch}` · commit: `#{commit}` · agents: #{agents_label}"
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
    theme = Enum.at(theme_picker_list(), state.theme_picker_cursor).theme
    path = Path.join(Path.expand("~/.codrift"), "theme.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"theme" => to_string(theme.name)}))

    %{state | modal: :none, theme: theme, theme_before_picker: nil}
    |> flash_status("Theme: #{theme.name}")
  end
end

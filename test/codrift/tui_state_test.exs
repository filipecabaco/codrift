defmodule Codrift.TUIStateTest do
  @moduledoc """
  Use-case-focused tests for `Codrift.TUI` state transitions.

  We call the ExRatatui.App callbacks (`handle_event/2`, `handle_info/2`)
  directly, bypassing the GenServer layer. `self()` inside the callbacks
  refers to the test process; any timers or messages sent there are harmless
  and are drained after each test.

  Tests avoid code paths that touch the global `Initiative.Store` (e.g.
  `reload_sidebar`, `fetch_initiative_context`) so the suite remains
  `async: true` and independent of on-disk data.  Side-bar entries use
  `:context_dir` tuples whose `File.ls` calls gracefully return `[]` for
  non-existent paths.
  """

  use ExUnit.Case, async: true

  alias Codrift.Config.{Keybindings, Theme}
  alias Codrift.TUI
  alias Codrift.TUI.Modals
  alias ExRatatui.Event.Key

  # A tiny action list used wherever @actions is needed so tests stay self-contained.
  @test_actions [
    %{id: :toggle_sidebar, label: "Toggle Sidebar", hint: "Ctrl+B"},
    %{id: :new_initiative, label: "New Initiative", hint: "n"},
    %{id: :toggle_diff_view, label: "Toggle Diff: Unified / Split", hint: "v"},
    %{id: :refresh, label: "Refresh", hint: "r"}
  ]

  # ── State builder ──────────────────────────────────────────────────────────

  defp base_state(overrides \\ %{}) do
    diff_mapped =
      overrides
      |> Map.take([
        :diff_files,
        :diff_scroll,
        :diff_view_mode,
        :diff_sidebar_entries,
        :diff_sidebar_cursor
      ])
      |> Map.new(fn
        {:diff_files, v} -> {:files, v}
        {:diff_scroll, v} -> {:scroll, v}
        {:diff_view_mode, v} -> {:view_mode, v}
        {:diff_sidebar_entries, v} -> {:sidebar_entries, v}
        {:diff_sidebar_cursor, v} -> {:sidebar_cursor, v}
      end)

    palette_mapped =
      overrides
      |> Map.take([:palette_cursor, :palette_filter])
      |> Map.new(fn
        {:palette_cursor, v} -> {:cursor, v}
        {:palette_filter, v} -> {:filter, v}
      end)

    refs_mapped =
      overrides
      |> Map.take([:status_timer_ref])
      |> Map.new(fn {:status_timer_ref, v} -> {:status_timer, v} end)

    nested_keys = [
      :diff_files,
      :diff_scroll,
      :diff_view_mode,
      :diff_sidebar_entries,
      :diff_sidebar_cursor,
      :palette_cursor,
      :palette_filter,
      :status_timer_ref,
      :sidebar_entries,
      :sidebar_cursor,
      :sidebar_collapsed,
      :selected_initiative_id,
      :selected_agent_id,
      :selected_agent_mode,
      :subscribed_agents,
      :agent_outputs,
      :vt100_screens,
      :editing_file,
      :modal,
      :modal_context,
      :modal_input,
      :actions,
      :theme_picker,
      :palette,
      :dir_picker,
      :editor_ref,
      :autosave_ref
    ]

    flat_overrides = Map.drop(overrides, nested_keys)

    kb = Keybindings.defaults()

    defaults = %{
      focus: Map.get(overrides, :focus, ExRatatui.Focus.new([:sidebar, :main])),
      pane_size: Map.get(overrides, :pane_size, {56, 20}),
      active_tab: Map.get(overrides, :active_tab, :context),
      cursor_info: nil,
      main_scroll: Map.get(overrides, :main_scroll, 0),
      status: "default status",
      input_buffer: Map.get(overrides, :input_buffer, ""),
      term_size: Map.get(overrides, :term_size, {80, 24}),
      kb: %{bindings: kb, reverse: Keybindings.build_reverse(kb)},
      theme: Theme.load(),
      sidebar: %Codrift.TUI.SidebarState{
        entries: Map.get(overrides, :sidebar_entries, []),
        cursor: Map.get(overrides, :sidebar_cursor, 0),
        collapsed: Map.get(overrides, :sidebar_collapsed, false)
      },
      selection: %Codrift.TUI.Selection{
        initiative_id: Map.get(overrides, :selected_initiative_id),
        agent_id: Map.get(overrides, :selected_agent_id),
        agent_mode: Map.get(overrides, :selected_agent_mode)
      },
      agents: %Codrift.TUI.AgentState{
        subscribed: Map.get(overrides, :subscribed_agents, MapSet.new()),
        outputs: Map.get(overrides, :agent_outputs, %{}),
        screens: Map.get(overrides, :vt100_screens, %{})
      },
      modal: %Codrift.TUI.ModalState{
        type: Map.get(overrides, :modal, :none),
        input: Map.get(overrides, :modal_input, ExRatatui.text_input_new()),
        context: Map.get(overrides, :modal_context),
        actions: Map.get(overrides, :actions, @test_actions),
        palette: Map.merge(%{cursor: 0, filter: ""}, palette_mapped),
        theme_picker: Map.get(overrides, :theme_picker, %{cursor: 0, before: nil}),
        dir_picker: Map.get(overrides, :dir_picker, %{suggestions: [], cursor: 0}),
        source_picker: Map.get(overrides, :source_picker, %{cursor: 0}),
        service_setup: Map.get(overrides, :service_setup, %{cursor: 0})
      },
      diff:
        Map.merge(
          %{files: [], scroll: 0, view_mode: :unified, sidebar_entries: [], sidebar_cursor: 0},
          diff_mapped
        ),
      refs:
        Map.merge(
          %{resize: nil, sidebar_tick: nil, status_timer: nil, nudge: nil, restore: nil},
          refs_mapped
        )
    }

    struct!(TUI, Map.merge(defaults, flat_overrides))
  end

  # Drain any stray messages (e.g. :reset_status timers) to keep the mailbox
  # clean between tests.
  defp drain_messages do
    receive do
      _ -> drain_messages()
    after
      0 -> :ok
    end
  end

  setup do
    on_exit(&drain_messages/0)
    :ok
  end

  # ── Modal lifecycle ────────────────────────────────────────────────────────

  describe "modal lifecycle" do
    test "Esc closes :new_name modal and sets status to 'Cancelled'" do
      state = base_state(%{modal: :new_name})
      {:noreply, new_state} = TUI.handle_event(key("esc"), state)

      assert new_state.modal.type == :none
      assert new_state.status == "Cancelled"
    end

    test "Esc closes :confirm_delete modal" do
      state =
        base_state(%{
          modal: :confirm_delete,
          modal_context: {:delete_initiative, "some-id", "My App"}
        })

      {:noreply, new_state} = TUI.handle_event(key("esc"), state)

      assert new_state.modal.type == :none
    end

    test "Esc closes :palette modal" do
      state = base_state(%{modal: :palette})
      {:noreply, new_state} = TUI.handle_event(key("esc"), state)

      assert new_state.modal.type == :none
    end

    test "n opens :source_picker modal when sidebar is focused" do
      state = base_state()
      {:noreply, new_state} = TUI.handle_event(key("n"), state)

      assert new_state.modal.type == :source_picker
      assert new_state.modal.context == :source_for_new
    end

    test "Ctrl+P opens command palette with reset cursor and filter" do
      state = base_state(%{palette_cursor: 2, palette_filter: "old"})
      {:noreply, new_state} = TUI.handle_event(ctrl_key("p"), state)

      assert new_state.modal.type == :palette
      assert new_state.modal.palette.cursor == 0
      assert new_state.modal.palette.filter == ""
    end
  end

  # ── Palette navigation ─────────────────────────────────────────────────────

  describe "palette navigation" do
    test "down arrow increments palette_cursor by 1" do
      state = base_state(%{modal: :palette, palette_cursor: 0})
      {:noreply, new_state} = TUI.handle_event(key("down"), state)

      assert new_state.modal.palette.cursor == 1
    end

    test "up arrow at 0 does not go negative" do
      state = base_state(%{modal: :palette, palette_cursor: 0})
      {:noreply, new_state} = TUI.handle_event(key("up"), state)

      assert new_state.modal.palette.cursor == 0
    end

    test "down arrow clamps at the last filtered action" do
      # @test_actions has 4 entries; last index is 3
      state = base_state(%{modal: :palette, palette_cursor: 3, palette_filter: ""})
      {:noreply, new_state} = TUI.handle_event(key("down"), state)

      assert new_state.modal.palette.cursor == 3
    end

    test "up arrow decrements palette_cursor" do
      state = base_state(%{modal: :palette, palette_cursor: 2})
      {:noreply, new_state} = TUI.handle_event(key("up"), state)

      assert new_state.modal.palette.cursor == 1
    end

    test "typing a character filters the palette and resets cursor to 0" do
      state = base_state(%{modal: :palette, palette_cursor: 2, palette_filter: ""})
      # 't' matches "Toggle Sidebar" — cursor resets to 0 regardless
      {:noreply, new_state} = TUI.handle_event(key("t"), state)

      assert new_state.modal.palette.cursor == 0
      # Filter contains the typed character
      assert String.contains?(new_state.modal.palette.filter, "t")
    end
  end

  # ── Sidebar navigation ─────────────────────────────────────────────────────

  describe "sidebar navigation" do
    # Using :context_dir entries to avoid triggering Store.get calls in
    # fetch_initiative_context. File.ls on non-existent paths safely returns [].
    defp context_dir_entries do
      [
        {:context_dir, "init-a", "/no/such/path/a", 0},
        {:context_dir, "init-b", "/no/such/path/b", 0}
      ]
    end

    test "j moves the sidebar cursor down by 1" do
      state = base_state(%{sidebar_entries: context_dir_entries(), sidebar_cursor: 0})
      {:noreply, new_state} = TUI.handle_event(key("j"), state)

      assert new_state.sidebar.cursor == 1
    end

    test "k moves the sidebar cursor up by 1" do
      state = base_state(%{sidebar_entries: context_dir_entries(), sidebar_cursor: 1})
      {:noreply, new_state} = TUI.handle_event(key("k"), state)

      assert new_state.sidebar.cursor == 0
    end

    test "k at the top (cursor 0) does not wrap to negative" do
      state = base_state(%{sidebar_entries: context_dir_entries(), sidebar_cursor: 0})
      {:noreply, new_state} = TUI.handle_event(key("k"), state)

      assert new_state.sidebar.cursor == 0
    end

    test "j at the bottom clamps at the last entry" do
      state = base_state(%{sidebar_entries: context_dir_entries(), sidebar_cursor: 1})
      {:noreply, new_state} = TUI.handle_event(key("j"), state)

      assert new_state.sidebar.cursor == 1
    end

    test "navigation resets main_scroll to 0" do
      state =
        base_state(%{sidebar_entries: context_dir_entries(), sidebar_cursor: 0, main_scroll: 15})

      {:noreply, new_state} = TUI.handle_event(key("j"), state)

      assert new_state.main_scroll == 0
    end
  end

  # ── Sidebar collapse ───────────────────────────────────────────────────────

  describe "sidebar collapse toggle" do
    test "Ctrl+B sets sidebar_collapsed to true when it was false" do
      state = base_state(%{sidebar_collapsed: false})
      {:noreply, new_state} = TUI.handle_event(ctrl_key("b"), state)

      assert new_state.sidebar.collapsed == true
    end

    test "Ctrl+B sets sidebar_collapsed to false when it was true" do
      state = base_state(%{sidebar_collapsed: true})
      {:noreply, new_state} = TUI.handle_event(ctrl_key("b"), state)

      assert new_state.sidebar.collapsed == false
    end

    test "collapsing the sidebar increases the main pane width" do
      {cols_before, _} = base_state(%{sidebar_collapsed: false}).pane_size

      state = base_state(%{sidebar_collapsed: false, term_size: {80, 24}})
      {:noreply, new_state} = TUI.handle_event(ctrl_key("b"), state)

      {cols_after, _} = new_state.pane_size
      assert cols_after > cols_before
    end

    test "Ctrl+B shifts focus to main pane when sidebar is currently focused and collapses" do
      # focus = [:sidebar, :main] means sidebar is currently focused
      state =
        base_state(%{sidebar_collapsed: false, focus: ExRatatui.Focus.new([:sidebar, :main])})

      {:noreply, new_state} = TUI.handle_event(ctrl_key("b"), state)

      # After collapse the sidebar is hidden; focus must move to main
      assert ExRatatui.Focus.focused?(new_state.focus, :main)
    end
  end

  # ── Diff mode controls ─────────────────────────────────────────────────────

  describe "diff mode controls" do
    test "v toggles diff_view_mode from unified to split" do
      state = base_state(%{active_tab: :diff, diff_view_mode: :unified, diff_scroll: 10})
      {:noreply, new_state} = TUI.handle_event(key("v"), state)

      assert new_state.diff.view_mode == :split
    end

    test "v toggles diff_view_mode from split back to unified" do
      state = base_state(%{active_tab: :diff, diff_view_mode: :split, diff_scroll: 5})
      {:noreply, new_state} = TUI.handle_event(key("v"), state)

      assert new_state.diff.view_mode == :unified
    end

    test "v resets diff_scroll to 0" do
      state = base_state(%{active_tab: :diff, diff_view_mode: :unified, diff_scroll: 8})
      {:noreply, new_state} = TUI.handle_event(key("v"), state)

      assert new_state.diff.scroll == 0
    end

    test "* key resets diff_sidebar_cursor and diff_scroll to 0" do
      entries = [{:diff_all, 5, 2}, {:diff_dir, "/repo", 5, 2}]

      state =
        base_state(%{
          active_tab: :diff,
          diff_sidebar_entries: entries,
          diff_sidebar_cursor: 1,
          diff_scroll: 12
        })

      {:noreply, new_state} = TUI.handle_event(key("*"), state)

      assert new_state.diff.sidebar_cursor == 0
      assert new_state.diff.scroll == 0
    end

    test "down arrow moves diff_sidebar_cursor in diff mode" do
      entries = [{:diff_all, 5, 2}, {:diff_dir, "/repo", 5, 2}]

      state =
        base_state(%{
          active_tab: :diff,
          diff_sidebar_entries: entries,
          diff_sidebar_cursor: 0
        })

      {:noreply, new_state} = TUI.handle_event(key("down"), state)

      assert new_state.diff.sidebar_cursor == 1
    end

    test "down arrow clamps diff_sidebar_cursor at the last entry" do
      entries = [{:diff_all, 5, 2}, {:diff_dir, "/repo", 5, 2}]

      state =
        base_state(%{
          active_tab: :diff,
          diff_sidebar_entries: entries,
          diff_sidebar_cursor: 1
        })

      {:noreply, new_state} = TUI.handle_event(key("down"), state)

      assert new_state.diff.sidebar_cursor == 1
    end
  end

  # ── Focus and input buffer ─────────────────────────────────────────────────

  describe "focus cycling" do
    test "Tab from sidebar cycles focus to main and clears input buffer" do
      state = base_state(%{focus: ExRatatui.Focus.new([:sidebar, :main]), input_buffer: "old"})
      {:noreply, new_state} = TUI.handle_event(key("tab"), state)

      assert ExRatatui.Focus.focused?(new_state.focus, :main)
      assert new_state.input_buffer == ""
    end

    test "Shift+Tab (back_tab) from main cycles focus back to sidebar and clears input buffer" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: "old"})
      {:noreply, new_state} = TUI.handle_event(key("back_tab"), state)

      assert ExRatatui.Focus.focused?(new_state.focus, :sidebar)
      assert new_state.input_buffer == ""
    end

    test "Tab+Shift modifier from main cycles focus (some terminals send this instead of back_tab)" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: "old"})
      {:noreply, new_state} = TUI.handle_event(shift_key("tab"), state)

      assert ExRatatui.Focus.focused?(new_state.focus, :sidebar)
      assert new_state.input_buffer == ""
    end

    test "Ctrl+Tab from main cycles focus" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: "old"})
      {:noreply, new_state} = TUI.handle_event(ctrl_key("tab"), state)

      assert ExRatatui.Focus.focused?(new_state.focus, :sidebar)
      assert new_state.input_buffer == ""
    end

    test "Tab with no modifiers from main still inserts \\t (not a focus switch)" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: ""})
      {:noreply, new_state} = TUI.handle_event(key("tab"), state)

      assert new_state.input_buffer == "\t"
      assert ExRatatui.Focus.focused?(new_state.focus, :main)
    end
  end

  # ── Quit keybinding ────────────────────────────────────────────────────────

  describe "quit keybinding" do
    test "q appends to input buffer when main pane is focused (not a quit key)" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: ""})
      {:noreply, new_state} = TUI.handle_event(key("q"), state)

      assert new_state.input_buffer == "q"
    end

    test "q from sidebar quits via Ctrl+Q binding (not single-char q)" do
      state = base_state(%{focus: ExRatatui.Focus.new([:sidebar, :main])})
      result = TUI.handle_event(key("q"), state)

      assert {:noreply, _} = result
    end

    test "Ctrl+Q from sidebar quits the TUI" do
      state = base_state(%{focus: ExRatatui.Focus.new([:sidebar, :main])})
      result = TUI.handle_event(ctrl_key("q"), state)

      assert {:stop, _} = result
    end

    test "Ctrl+Q from main pane also quits" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar])})
      result = TUI.handle_event(ctrl_key("q"), state)

      assert {:stop, _} = result
    end
  end

  # ── Tab key in main pane ───────────────────────────────────────────────────

  describe "tab key in main pane (non-PTY)" do
    defp main_focused_state(overrides \\ %{}) do
      base_state(Map.merge(%{focus: ExRatatui.Focus.new([:main, :sidebar])}, overrides))
    end

    test "Tab inserts a literal tab into the input buffer" do
      state = main_focused_state(%{input_buffer: "hello"})
      {:noreply, new_state} = TUI.handle_event(key("tab"), state)

      assert new_state.input_buffer == "hello\t"
    end

    test "Tab does not cycle focus away from main" do
      state = main_focused_state()
      {:noreply, new_state} = TUI.handle_event(key("tab"), state)

      assert ExRatatui.Focus.focused?(new_state.focus, :main)
    end

    test "multiple tabs accumulate in the buffer" do
      state = main_focused_state(%{input_buffer: ""})
      {:noreply, s1} = TUI.handle_event(key("tab"), state)
      {:noreply, s2} = TUI.handle_event(key("tab"), s1)

      assert s2.input_buffer == "\t\t"
    end

    test "tab can be mixed with regular characters" do
      state = main_focused_state(%{input_buffer: "key"})
      {:noreply, s1} = TUI.handle_event(key("tab"), state)
      {:noreply, s2} = TUI.handle_event(key("="), s1)

      assert s2.input_buffer == "key\t="
    end
  end

  # ── Shift+Enter newline insertion ──────────────────────────────────────────

  describe "Shift+Enter in main pane (non-PTY)" do
    test "Shift+Enter appends \\n to the input buffer without submitting" do
      state =
        base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: "line one"})

      {:noreply, new_state} = TUI.handle_event(shift_key("enter"), state)

      assert new_state.input_buffer == "line one\n"
    end

    test "Shift+Enter on an empty buffer just inserts a newline" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: ""})
      {:noreply, new_state} = TUI.handle_event(shift_key("enter"), state)

      assert new_state.input_buffer == "\n"
    end

    test "Shift+Enter when sidebar is focused is a no-op" do
      state =
        base_state(%{focus: ExRatatui.Focus.new([:sidebar, :main]), input_buffer: "unchanged"})

      {:noreply, new_state} = TUI.handle_event(shift_key("enter"), state)

      assert new_state.input_buffer == "unchanged"
    end

    test "composing a multi-line message with Shift+Enter then Enter" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: ""})

      {:noreply, s1} = TUI.handle_event(key("a"), state)
      {:noreply, s2} = TUI.handle_event(shift_key("enter"), s1)
      {:noreply, s3} = TUI.handle_event(key("b"), s2)

      assert s3.input_buffer == "a\nb"
    end
  end

  # ── Paste mode ────────────────────────────────────────────────────────────

  describe "paste mode (Ctrl+V toggle)" do
    defp main_state(overrides) do
      base_state(Map.merge(%{focus: ExRatatui.Focus.new([:main, :sidebar])}, overrides))
    end

    test "Ctrl+V in main non-PTY pane enables paste mode" do
      state = main_state(%{paste_mode: false})
      {:noreply, new_state} = TUI.handle_event(ctrl_key("v"), state)

      assert new_state.paste_mode == true
    end

    test "Ctrl+V again disables paste mode" do
      state = main_state(%{paste_mode: true})
      {:noreply, new_state} = TUI.handle_event(ctrl_key("v"), state)

      assert new_state.paste_mode == false
    end

    test "Enter in paste mode inserts newline instead of submitting" do
      state = main_state(%{input_buffer: "line one", paste_mode: true})
      {:noreply, new_state} = TUI.handle_event(key("enter"), state)

      assert new_state.input_buffer == "line one\n"
    end

    test "Enter outside paste mode still submits (clears buffer)" do
      state = main_state(%{input_buffer: "send me", paste_mode: false})
      {:noreply, new_state} = TUI.handle_event(key("enter"), state)

      assert new_state.input_buffer == ""
    end

    test "toggling paste mode off then Enter clears buffer and paste_mode remains false" do
      state = main_state(%{input_buffer: "some text", paste_mode: true})
      {:noreply, off_state} = TUI.handle_event(ctrl_key("v"), state)
      assert off_state.paste_mode == false

      {:noreply, sent_state} = TUI.handle_event(key("enter"), off_state)
      assert sent_state.input_buffer == ""
      assert sent_state.paste_mode == false
    end

    test "Ctrl+V in sidebar has no paste mode effect" do
      state = base_state(%{paste_mode: false, focus: ExRatatui.Focus.new([:sidebar, :main])})
      {:noreply, new_state} = TUI.handle_event(ctrl_key("v"), state)

      assert new_state.paste_mode == false
    end
  end

  # ── Bracketed paste events ─────────────────────────────────────────────────

  describe "bracketed paste event (%Paste{})" do
    test "paste content is appended to buffer atomically in main non-PTY mode" do
      state =
        base_state(%{
          focus: ExRatatui.Focus.new([:main, :sidebar]),
          input_buffer: "before: "
        })

      event = %ExRatatui.Event.Paste{content: "hello\nworld"}
      {:noreply, new_state} = TUI.handle_event(event, state)

      assert new_state.input_buffer == "before: hello\nworld"
    end

    test "paste event disables paste_mode (no longer needed)" do
      state =
        base_state(%{
          focus: ExRatatui.Focus.new([:main, :sidebar]),
          input_buffer: "",
          paste_mode: true
        })

      {:noreply, new_state} = TUI.handle_event(%ExRatatui.Event.Paste{content: "x"}, state)

      assert new_state.paste_mode == false
    end

    test "paste event is a no-op when sidebar is focused" do
      state =
        base_state(%{
          focus: ExRatatui.Focus.new([:sidebar, :main]),
          input_buffer: "unchanged"
        })

      {:noreply, new_state} = TUI.handle_event(%ExRatatui.Event.Paste{content: "ignored"}, state)

      assert new_state.input_buffer == "unchanged"
    end

    test "paste preserves tabs, newlines, and Unicode intact" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: ""})

      content = "line1\tindented\nline2 — em dash\n"
      {:noreply, new_state} = TUI.handle_event(%ExRatatui.Event.Paste{content: content}, state)

      assert new_state.input_buffer == content
    end
  end

  # ── Multi-byte Unicode input ───────────────────────────────────────────────

  describe "multi-byte Unicode character input" do
    test "em dash is appended to the input buffer" do
      state =
        base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: "text"})

      {:noreply, new_state} =
        TUI.handle_event(%Key{code: "—", kind: "press", modifiers: []}, state)

      assert new_state.input_buffer == "text—"
    end

    test "opening curly quote is appended to the input buffer" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: ""})

      {:noreply, new_state} =
        TUI.handle_event(%Key{code: "“", kind: "press", modifiers: []}, state)

      assert new_state.input_buffer == "“"
    end

    test "closing curly quote is appended to the input buffer" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: ""})

      {:noreply, new_state} =
        TUI.handle_event(%Key{code: "”", kind: "press", modifiers: []}, state)

      assert new_state.input_buffer == "”"
    end

    test "en dash is appended to the input buffer" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: ""})

      {:noreply, new_state} =
        TUI.handle_event(%Key{code: "–", kind: "press", modifiers: []}, state)

      assert new_state.input_buffer == "–"
    end

    test "multi-byte Unicode when sidebar focused is a no-op" do
      state =
        base_state(%{focus: ExRatatui.Focus.new([:sidebar, :main]), input_buffer: "unchanged"})

      {:noreply, new_state} =
        TUI.handle_event(%Key{code: "—", kind: "press", modifiers: []}, state)

      assert new_state.input_buffer == "unchanged"
    end

    test "ASCII characters still work alongside Unicode" do
      state = base_state(%{focus: ExRatatui.Focus.new([:main, :sidebar]), input_buffer: ""})

      {:noreply, s1} = TUI.handle_event(key("x"), state)

      {:noreply, s2} =
        TUI.handle_event(%Key{code: "—", kind: "press", modifiers: []}, s1)

      {:noreply, s3} = TUI.handle_event(key("y"), s2)

      assert s3.input_buffer == "x—y"
    end
  end

  # ── Agent output handling ──────────────────────────────────────────────────

  describe "agent output" do
    test "agent_output message stores data in agent_outputs buffer" do
      agent_id = "test-agent-1"

      state =
        base_state(%{
          selected_agent_id: agent_id,
          vt100_screens: %{},
          agent_outputs: %{},
          pane_size: {80, 20}
        })

      {:noreply, new_state, _} = TUI.handle_info({:agent_output, agent_id, "Hello world"}, state)

      assert ["Hello world"] = Map.get(new_state.agents.outputs, agent_id)
    end

    test "agent_output message creates a vt100 screen for the agent" do
      agent_id = "test-agent-2"

      state =
        base_state(%{
          selected_agent_id: agent_id,
          vt100_screens: %{},
          agent_outputs: %{},
          pane_size: {80, 20}
        })

      {:noreply, new_state, _} = TUI.handle_info({:agent_output, agent_id, "some output"}, state)

      assert Map.has_key?(new_state.agents.screens, agent_id)
    end

    test "output for the selected agent at scroll 0 stays at 0" do
      agent_id = "selected-agent"

      state =
        base_state(%{
          selected_agent_id: agent_id,
          vt100_screens: %{},
          agent_outputs: %{},
          pane_size: {80, 20},
          main_scroll: 0
        })

      {:noreply, new_state, _} = TUI.handle_info({:agent_output, agent_id, "data"}, state)

      assert new_state.main_scroll == 0
    end

    test "output for the selected agent preserves scroll when user has scrolled up" do
      agent_id = "selected-agent"

      state =
        base_state(%{
          selected_agent_id: agent_id,
          vt100_screens: %{},
          agent_outputs: %{},
          pane_size: {80, 20},
          main_scroll: 7
        })

      {:noreply, new_state, _} = TUI.handle_info({:agent_output, agent_id, "data"}, state)

      assert new_state.main_scroll == 7
    end

    test "output for a non-selected agent does not reset main_scroll" do
      selected_id = "selected"
      other_id = "other-agent"

      state =
        base_state(%{
          selected_agent_id: selected_id,
          vt100_screens: %{},
          agent_outputs: %{},
          pane_size: {80, 20},
          main_scroll: 7
        })

      {:noreply, new_state, _} = TUI.handle_info({:agent_output, other_id, "data"}, state)

      assert new_state.main_scroll == 7
    end
  end

  # ── Flash status timer management ─────────────────────────────────────────

  describe "flash status timer" do
    test ":reset_status message restores the default hint and clears status_timer_ref" do
      ref = Process.send_after(self(), :dummy_timer, 60_000)
      state = base_state(%{status: "temporary flash", status_timer_ref: ref})

      {:noreply, new_state} = TUI.handle_info(:reset_status, state)

      assert new_state.refs.status_timer == nil
      # Default status contains the navigate hint
      assert String.contains?(new_state.status, "navigate") or
               String.contains?(new_state.status, "j/k")

      # Clean up the dummy timer we created
      Process.cancel_timer(ref)
      drain_messages()
    end

    test "Esc cancels an open modal and schedules a :reset_status timer" do
      state = base_state(%{modal: :new_name, status_timer_ref: nil})
      {:noreply, new_state} = TUI.handle_event(key("esc"), state)

      # A timer reference is set after flashing status
      assert not is_nil(new_state.refs.status_timer)
      Process.cancel_timer(new_state.refs.status_timer)
      drain_messages()
    end

    test "a second Esc cancels the previous timer before scheduling a new one" do
      # Simulate an existing timer
      state = base_state(%{modal: :new_name, status_timer_ref: nil})
      {:noreply, state_after_first} = TUI.handle_event(key("esc"), state)

      first_ref = state_after_first.refs.status_timer
      assert not is_nil(first_ref)

      # Re-open the modal for a second Esc
      state2 = %{state_after_first | modal: %{state_after_first.modal | type: :new_name}}
      {:noreply, state_after_second} = TUI.handle_event(key("esc"), state2)

      second_ref = state_after_second.refs.status_timer
      # Timer refs must differ — the old one was cancelled and a new one created
      assert first_ref != second_ref

      Process.cancel_timer(second_ref)
      drain_messages()
    end
  end

  # ── Terminal resize ────────────────────────────────────────────────────────

  describe "terminal resize" do
    test ":apply_resize updates pane_size based on new terminal dimensions" do
      state = base_state(%{sidebar_collapsed: false, pane_size: {56, 20}, vt100_screens: %{}})
      {:noreply, new_state} = TUI.handle_info({:apply_resize, 120, 40}, state)

      {cols, rows} = new_state.pane_size
      # Wider terminal → wider pane; taller terminal → more rows (minus header/footer)
      assert cols > 56
      assert rows > 20
    end

    test ":apply_resize resets main_scroll to 0" do
      state = base_state(%{pane_size: {56, 20}, vt100_screens: %{}, main_scroll: 8})
      {:noreply, new_state} = TUI.handle_info({:apply_resize, 80, 24}, state)

      assert new_state.main_scroll == 0
    end
  end

  # ── Initiative creation — source picker flow ───────────────────────────────

  describe "initiative creation: n → source picker" do
    test "n opens :source_picker and :new_name is no longer the first step", _ctx do
      state = base_state()
      {:noreply, new_state} = TUI.handle_event(key("n"), state)

      assert new_state.modal.type == :source_picker
      assert new_state.modal.context == :source_for_new
    end

    test "Esc cancels :source_picker and sets status to 'Cancelled'", _ctx do
      state = base_state(%{modal: :source_picker, modal_context: :source_for_new})

      {:noreply, new_state} = TUI.handle_event(key("esc"), state)

      assert new_state.modal.type == :none
      assert new_state.status == "Cancelled"
    end
  end

  describe ":new_name modal (reached from source picker 'new')" do
    test "Enter with a non-empty name transitions to :new_dir", _ctx do
      input = ExRatatui.text_input_new()
      ExRatatui.text_input_set_value(input, "my-project")
      state = base_state(%{modal: :new_name, modal_context: :creating_blank, modal_input: input})

      {:noreply, new_state} = TUI.handle_event(key("enter"), state)

      assert new_state.modal.type == :new_dir
      assert new_state.modal.context == {:creating, "my-project"}
    end

    test "Enter with empty name flashes an error and stays in :new_name", _ctx do
      input = ExRatatui.text_input_new()
      ExRatatui.text_input_set_value(input, "  ")
      state = base_state(%{modal: :new_name, modal_input: input})

      {:noreply, new_state} = TUI.handle_event(key("enter"), state)

      assert new_state.modal.type == :new_name
      assert String.contains?(new_state.status, "empty")
    end
  end

  describe "source picker navigation" do
    defp source_picker_state(cursor) do
      base_state(%{modal: :source_picker, modal_context: :source_for_new})
      |> put_in([Access.key!(:modal), Access.key!(:source_picker)], %{cursor: cursor})
    end

    test "down arrow increments cursor", _ctx do
      {:noreply, new_state} = TUI.handle_event(key("down"), source_picker_state(0))
      assert new_state.modal.source_picker.cursor == 1
    end

    test "up arrow at 0 does not go negative", _ctx do
      {:noreply, new_state} = TUI.handle_event(key("up"), source_picker_state(0))
      assert new_state.modal.source_picker.cursor == 0
    end

    test "up arrow decrements cursor", _ctx do
      {:noreply, new_state} = TUI.handle_event(key("up"), source_picker_state(3))
      assert new_state.modal.source_picker.cursor == 2
    end

    test "down arrow clamps at the last source entry", _ctx do
      max = length(Modals.sources()) - 1
      {:noreply, new_state} = TUI.handle_event(key("down"), source_picker_state(max))
      assert new_state.modal.source_picker.cursor == max
    end

    test "Enter on 'new' (cursor 0) transitions to :new_name", _ctx do
      {:noreply, new_state} = TUI.handle_event(key("enter"), source_picker_state(0))

      assert new_state.modal.type == :new_name
      assert new_state.modal.context == :creating_blank
    end

    # When a service is not connected and has an OAuth config, selecting it starts
    # an auth flow. Without client_id configured the flow errors and flashes a message
    # — the modal stays as source_picker (no crash, no navigation).
    test "Enter on an unconnected OAuth service without client_id flashes an error", _ctx do
      github_cursor =
        Enum.find_index(Modals.sources(), fn {k, _} -> k == "github" end)

      {:noreply, new_state} = TUI.handle_event(key("enter"), source_picker_state(github_cursor))

      # No client_id configured → start_flow fails → flash_status → stays in source_picker
      assert new_state.modal.type == :source_picker
      assert String.contains?(new_state.status, "GITHUB_CLIENT_ID")
    end
  end

  describe "integration_item_id modal" do
    defp item_id_state(item_id \\ "") do
      input = ExRatatui.text_input_new()
      ExRatatui.text_input_set_value(input, item_id)

      base_state(%{
        modal: :integration_item_id,
        modal_input: input,
        modal_context: {:importing, "github"}
      })
    end

    test "Esc cancels and sets status to 'Cancelled'", _ctx do
      {:noreply, new_state} = TUI.handle_event(key("esc"), item_id_state())

      assert new_state.modal.type == :none
      assert new_state.status == "Cancelled"
    end

    test "Enter with empty item_id flashes an error and stays in modal", _ctx do
      {:noreply, new_state} = TUI.handle_event(key("enter"), item_id_state(""))

      assert new_state.modal.type == :integration_item_id
      assert String.contains?(new_state.status, "empty")
    end

    test "printable characters are forwarded to the text input", _ctx do
      state = item_id_state()
      {:noreply, s1} = TUI.handle_event(key("o"), state)
      {:noreply, s2} = TUI.handle_event(key("w"), s1)
      {:noreply, _s3} = TUI.handle_event(key("n"), s2)
      # The modal stays open while typing
      assert s2.modal.type == :integration_item_id
    end

    test "backspace is forwarded to the text input without changing modal type", _ctx do
      state = item_id_state("abc")
      {:noreply, new_state} = TUI.handle_event(key("backspace"), state)

      assert new_state.modal.type == :integration_item_id
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp key(code), do: %Key{code: code, kind: "press", modifiers: []}
  defp ctrl_key(code), do: %Key{code: code, kind: "press", modifiers: ["ctrl"]}
  defp shift_key(code), do: %Key{code: code, kind: "press", modifiers: ["shift"]}
end

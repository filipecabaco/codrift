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

  alias Codrift.TUI
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
    defaults = %{
      focus: ExRatatui.Focus.new([:sidebar, :main]),
      sidebar_entries: [],
      sidebar_cursor: 0,
      selected_initiative_id: nil,
      selected_agent_id: nil,
      subscribed_agents: MapSet.new(),
      agent_outputs: %{},
      vt100_screens: %{},
      pane_size: {56, 20},
      active_tab: :context,
      diff_files: [],
      cursor_info: nil,
      main_scroll: 0,
      status: "default status",
      modal: :none,
      modal_input: ExRatatui.text_input_new(),
      modal_context: nil,
      dir_suggestions: [],
      dir_suggestion_cursor: 0,
      palette_cursor: 0,
      palette_filter: "",
      actions: @test_actions,
      input_buffer: "",
      selected_agent_mode: nil,
      resize_ref: nil,
      sidebar_tick_ref: nil,
      editor_ref: ExRatatui.textarea_new(),
      editing_file: nil,
      autosave_ref: nil,
      term_size: {80, 24},
      diff_scroll: 0,
      diff_view_mode: :unified,
      diff_sidebar_entries: [],
      diff_sidebar_cursor: 0,
      sidebar_collapsed: false,
      status_timer_ref: nil
    }

    struct!(TUI, Map.merge(defaults, overrides))
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

      assert new_state.modal == :none
      assert new_state.status == "Cancelled"
    end

    test "Esc closes :confirm_delete modal" do
      state =
        base_state(%{
          modal: :confirm_delete,
          modal_context: {:delete_initiative, "some-id", "My App"}
        })

      {:noreply, new_state} = TUI.handle_event(key("esc"), state)

      assert new_state.modal == :none
    end

    test "Esc closes :palette modal" do
      state = base_state(%{modal: :palette})
      {:noreply, new_state} = TUI.handle_event(key("esc"), state)

      assert new_state.modal == :none
    end

    test "n key opens :new_name modal when sidebar is focused" do
      state = base_state()
      {:noreply, new_state} = TUI.handle_event(key("n"), state)

      assert new_state.modal == :new_name
    end

    test "Ctrl+P opens command palette with reset cursor and filter" do
      state = base_state(%{palette_cursor: 2, palette_filter: "old"})
      {:noreply, new_state} = TUI.handle_event(ctrl_key("p"), state)

      assert new_state.modal == :palette
      assert new_state.palette_cursor == 0
      assert new_state.palette_filter == ""
    end
  end

  # ── Palette navigation ─────────────────────────────────────────────────────

  describe "palette navigation" do
    test "down arrow increments palette_cursor by 1" do
      state = base_state(%{modal: :palette, palette_cursor: 0})
      {:noreply, new_state} = TUI.handle_event(key("down"), state)

      assert new_state.palette_cursor == 1
    end

    test "up arrow at 0 does not go negative" do
      state = base_state(%{modal: :palette, palette_cursor: 0})
      {:noreply, new_state} = TUI.handle_event(key("up"), state)

      assert new_state.palette_cursor == 0
    end

    test "down arrow clamps at the last filtered action" do
      # @test_actions has 4 entries; last index is 3
      state = base_state(%{modal: :palette, palette_cursor: 3, palette_filter: ""})
      {:noreply, new_state} = TUI.handle_event(key("down"), state)

      assert new_state.palette_cursor == 3
    end

    test "up arrow decrements palette_cursor" do
      state = base_state(%{modal: :palette, palette_cursor: 2})
      {:noreply, new_state} = TUI.handle_event(key("up"), state)

      assert new_state.palette_cursor == 1
    end

    test "typing a character filters the palette and resets cursor to 0" do
      state = base_state(%{modal: :palette, palette_cursor: 2, palette_filter: ""})
      # 't' matches "Toggle Sidebar" — cursor resets to 0 regardless
      {:noreply, new_state} = TUI.handle_event(key("t"), state)

      assert new_state.palette_cursor == 0
      # Filter contains the typed character
      assert String.contains?(new_state.palette_filter, "t")
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

    test "j key moves the sidebar cursor down by 1" do
      state = base_state(%{sidebar_entries: context_dir_entries(), sidebar_cursor: 0})
      {:noreply, new_state} = TUI.handle_event(key("j"), state)

      assert new_state.sidebar_cursor == 1
    end

    test "k key moves the sidebar cursor up by 1" do
      state = base_state(%{sidebar_entries: context_dir_entries(), sidebar_cursor: 1})
      {:noreply, new_state} = TUI.handle_event(key("k"), state)

      assert new_state.sidebar_cursor == 0
    end

    test "k at the top (cursor 0) does not wrap to negative" do
      state = base_state(%{sidebar_entries: context_dir_entries(), sidebar_cursor: 0})
      {:noreply, new_state} = TUI.handle_event(key("k"), state)

      assert new_state.sidebar_cursor == 0
    end

    test "j at the bottom clamps at the last entry" do
      state = base_state(%{sidebar_entries: context_dir_entries(), sidebar_cursor: 1})
      {:noreply, new_state} = TUI.handle_event(key("j"), state)

      assert new_state.sidebar_cursor == 1
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

      assert new_state.sidebar_collapsed == true
    end

    test "Ctrl+B sets sidebar_collapsed to false when it was true" do
      state = base_state(%{sidebar_collapsed: true})
      {:noreply, new_state} = TUI.handle_event(ctrl_key("b"), state)

      assert new_state.sidebar_collapsed == false
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
    test "v key toggles diff_view_mode from unified to split" do
      state = base_state(%{active_tab: :diff, diff_view_mode: :unified, diff_scroll: 10})
      {:noreply, new_state} = TUI.handle_event(key("v"), state)

      assert new_state.diff_view_mode == :split
    end

    test "v key toggles diff_view_mode from split back to unified" do
      state = base_state(%{active_tab: :diff, diff_view_mode: :split, diff_scroll: 5})
      {:noreply, new_state} = TUI.handle_event(key("v"), state)

      assert new_state.diff_view_mode == :unified
    end

    test "v key resets diff_scroll to 0" do
      state = base_state(%{active_tab: :diff, diff_view_mode: :unified, diff_scroll: 8})
      {:noreply, new_state} = TUI.handle_event(key("v"), state)

      assert new_state.diff_scroll == 0
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

      assert new_state.diff_sidebar_cursor == 0
      assert new_state.diff_scroll == 0
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

      assert new_state.diff_sidebar_cursor == 1
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

      assert new_state.diff_sidebar_cursor == 1
    end
  end

  # ── Focus and input buffer ─────────────────────────────────────────────────

  describe "focus cycling" do
    test "Tab key clears the input buffer" do
      state = base_state(%{input_buffer: "unfinished input"})
      {:noreply, new_state} = TUI.handle_event(key("tab"), state)

      assert new_state.input_buffer == ""
    end

    test "Tab key cycles focus away from sidebar to main" do
      state = base_state(%{focus: ExRatatui.Focus.new([:sidebar, :main])})
      {:noreply, new_state} = TUI.handle_event(key("tab"), state)

      assert ExRatatui.Focus.focused?(new_state.focus, :main)
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

      {:noreply, new_state} = TUI.handle_info({:agent_output, agent_id, "Hello world"}, state)

      assert ["Hello world"] = Map.get(new_state.agent_outputs, agent_id)
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

      {:noreply, new_state} = TUI.handle_info({:agent_output, agent_id, "some output"}, state)

      assert Map.has_key?(new_state.vt100_screens, agent_id)
    end

    test "output for the selected agent resets main_scroll to 0" do
      agent_id = "selected-agent"

      state =
        base_state(%{
          selected_agent_id: agent_id,
          vt100_screens: %{},
          agent_outputs: %{},
          pane_size: {80, 20},
          main_scroll: 7
        })

      {:noreply, new_state} = TUI.handle_info({:agent_output, agent_id, "data"}, state)

      assert new_state.main_scroll == 0
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

      {:noreply, new_state} = TUI.handle_info({:agent_output, other_id, "data"}, state)

      assert new_state.main_scroll == 7
    end
  end

  # ── Flash status timer management ─────────────────────────────────────────

  describe "flash status timer" do
    test ":reset_status message restores the default hint and clears status_timer_ref" do
      ref = Process.send_after(self(), :dummy_timer, 60_000)
      state = base_state(%{status: "temporary flash", status_timer_ref: ref})

      {:noreply, new_state} = TUI.handle_info(:reset_status, state)

      assert new_state.status_timer_ref == nil
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
      assert not is_nil(new_state.status_timer_ref)
      Process.cancel_timer(new_state.status_timer_ref)
      drain_messages()
    end

    test "a second Esc cancels the previous timer before scheduling a new one" do
      # Simulate an existing timer
      state = base_state(%{modal: :new_name, status_timer_ref: nil})
      {:noreply, state_after_first} = TUI.handle_event(key("esc"), state)

      first_ref = state_after_first.status_timer_ref
      assert not is_nil(first_ref)

      # Re-open the modal for a second Esc
      state2 = %{state_after_first | modal: :new_name}
      {:noreply, state_after_second} = TUI.handle_event(key("esc"), state2)

      second_ref = state_after_second.status_timer_ref
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

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp key(code), do: %Key{code: code, kind: "press", modifiers: []}
  defp ctrl_key(code), do: %Key{code: code, kind: "press", modifiers: ["ctrl"]}
end

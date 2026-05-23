defmodule Codrift.TUI do
  @moduledoc """
  Terminal UI for Codrift, built on `ExRatatui.App`.

  ## Layout

      ┌──────────────────────────────────────────────┐
      │ ● Context  ○ 2: Diff                         │  mode indicator
      ├─────────────┬────────────────────────────────┤
      │ Initiatives │                                │
      │  └ 📁 dir   │  Context-driven main pane      │
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
  | `1` | Context mode (default) |
  | `2` | Diff mode for selected initiative |
  | `r` | Refresh current pane |
  | `Ctrl+D` / `Ctrl+U` | Scroll half-page |
  | `q` / `Ctrl+C` | Quit (kills all running agents) |
  """

  use ExRatatui.App

  alias ExRatatui.{Focus, Layout, Style}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Event.Key
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.CodeBlock
  alias ExRatatui.Widgets.Paragraph

  alias Codrift.{AgentProcess, AgentSupervisor, Diff}
  alias Codrift.Initiative.Store
  alias Codrift.TUI.{DirPicker, Modals, Sidebar, Styles}

  @type modal :: :none | :new_name | :new_dir | :confirm_delete | :palette
  @type tab :: :context | :diff

  defstruct [
    :focus,
    :sidebar_entries,
    :sidebar_cursor,
    :selected_initiative_id,
    :selected_agent_id,
    :agent_outputs,
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
    :actions
  ]

  @actions [
    %{id: :new_initiative, label: "New Initiative", hint: "n"},
    %{id: :add_dir, label: "Add Directory", hint: "a"},
    %{id: :start_claude, label: "Start Claude Agent", hint: "s"},
    %{id: :start_aider, label: "Start Aider Agent", hint: ""},
    %{id: :delete_current, label: "Delete / Stop Current", hint: "d"},
    %{id: :refresh, label: "Refresh", hint: "r"}
  ]

  @impl true
  def mount(_opts) do
    initiatives = Store.list()
    agents = Enum.map(AgentSupervisor.list_agents(), &AgentProcess.status/1)

    {:ok,
     %__MODULE__{
       focus: Focus.new([:sidebar, :main]),
       sidebar_entries: Sidebar.build_entries(initiatives, agents),
       sidebar_cursor: 0,
       selected_initiative_id: nil,
       selected_agent_id: nil,
       agent_outputs: %{},
       active_tab: :context,
       diff_files: [],
       cursor_info: nil,
       main_scroll: 0,
       status:
         "j/k:navigate  n:new  a:add-dir  s:start  d:delete/stop  2:diff  Ctrl+P:palette  q:quit",
       modal: :none,
       modal_input: ExRatatui.text_input_new(),
       modal_context: nil,
       dir_suggestions: [],
       dir_suggestion_cursor: 0,
       palette_cursor: 0,
       palette_filter: "",
       actions: @actions
     }}
  end

  @impl true
  def render(state, frame) do
    full = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [header_rect, body_rect, footer_rect] =
      Layout.split(full, :vertical, [{:length, 1}, {:min, 0}, {:length, 1}])

    [sidebar_rect, main_rect] =
      Layout.split(body_rect, :horizontal, [{:percentage, 30}, {:percentage, 70}])

    base = [
      {render_mode_bar(state), header_rect},
      {Sidebar.render(state.sidebar_entries, state.sidebar_cursor, state.focus), sidebar_rect},
      {render_main(state), main_rect},
      {render_footer(state), footer_rect}
    ]

    base ++ Modals.render(state, frame)
  end

  @impl true
  def handle_event(%Key{code: "c", kind: "press", modifiers: ["ctrl"]}, state),
    do: {:stop, state}

  def handle_event(%Key{code: "esc", kind: "press"}, %{modal: modal} = state)
      when modal != :none do
    {:noreply, %{state | modal: :none, status: "Cancelled"}}
  end

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :confirm_delete} = state) do
    {:noreply, do_delete(state)}
  end

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :new_name} = state) do
    {:noreply, confirm_name(state)}
  end

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :new_dir} = state) do
    {:noreply, confirm_dir(state)}
  end

  def handle_event(%Key{code: "enter", kind: "press"}, %{modal: :palette} = state) do
    {:noreply, execute_palette_action(state)}
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: :new_dir} = state) do
    {:noreply, DirPicker.move_cursor(state, -1)}
  end

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: :new_dir} = state) do
    {:noreply, DirPicker.move_cursor(state, 1)}
  end

  def handle_event(%Key{code: "tab", kind: "press"}, %{modal: :new_dir} = state) do
    {:noreply, DirPicker.complete(state)}
  end

  def handle_event(%Key{code: "up", kind: "press"}, %{modal: :palette} = state) do
    {:noreply, %{state | palette_cursor: max(state.palette_cursor - 1, 0)}}
  end

  def handle_event(%Key{code: "down", kind: "press"}, %{modal: :palette} = state) do
    max_idx = max(length(Modals.filter_actions(state.actions, state.palette_filter)) - 1, 0)
    {:noreply, %{state | palette_cursor: min(state.palette_cursor + 1, max_idx)}}
  end

  def handle_event(%Key{code: code, kind: "press"}, %{modal: modal} = state)
      when modal in [:new_name, :new_dir, :palette] and byte_size(code) == 1 do
    ExRatatui.text_input_handle_key(state.modal_input, code)
    {:noreply, sync_modal(state, modal)}
  end

  def handle_event(%Key{code: code, kind: "press"}, %{modal: modal} = state)
      when modal in [:new_name, :new_dir, :palette] and
             code in ["backspace", "delete", "left", "right", "home", "end"] do
    ExRatatui.text_input_handle_key(state.modal_input, code)
    {:noreply, sync_modal(state, modal)}
  end

  def handle_event(%Key{code: "q", kind: "press"}, %{modal: :none} = state),
    do: {:stop, state}

  def handle_event(%Key{code: code, kind: "press"} = key, %{modal: :none} = state)
      when code in ["tab", "back_tab"] do
    {new_focus, _} = Focus.handle_key(state.focus, key)
    {:noreply, %{state | focus: new_focus, main_scroll: 0}}
  end

  def handle_event(%Key{code: code, kind: "press"}, %{modal: :none} = state)
      when code in ["j", "down"] do
    {:noreply, navigate(state, 1)}
  end

  def handle_event(%Key{code: code, kind: "press"}, %{modal: :none} = state)
      when code in ["k", "up"] do
    {:noreply, navigate(state, -1)}
  end

  def handle_event(%Key{code: "n", kind: "press", modifiers: []}, %{modal: :none} = state) do
    ExRatatui.text_input_set_value(state.modal_input, "")
    {:noreply, %{state | modal: :new_name, status: "New initiative — Enter: next  Esc: cancel"}}
  end

  def handle_event(%Key{code: "a", kind: "press", modifiers: []}, %{modal: :none} = state) do
    {:noreply, open_add_dir_modal(state)}
  end

  def handle_event(%Key{code: "s", kind: "press", modifiers: []}, %{modal: :none} = state) do
    {:noreply, start_agent_at_cursor(state, Codrift.Agent.Adapters.Claude)}
  end

  def handle_event(%Key{code: "d", kind: "press", modifiers: []}, %{modal: :none} = state) do
    {:noreply, open_delete_confirm(state)}
  end

  def handle_event(%Key{code: "p", kind: "press", modifiers: ["ctrl"]}, %{modal: :none} = state) do
    ExRatatui.text_input_set_value(state.modal_input, "")
    {:noreply, %{state | modal: :palette, palette_cursor: 0, palette_filter: ""}}
  end

  def handle_event(%Key{code: "1", kind: "press"}, %{modal: :none} = state) do
    {:noreply, %{state | active_tab: :context, main_scroll: 0} |> update_context_from_cursor()}
  end

  def handle_event(%Key{code: "2", kind: "press"}, %{modal: :none} = state) do
    {:noreply, refresh_diff(%{state | active_tab: :diff, main_scroll: 0})}
  end

  def handle_event(%Key{code: "r", kind: "press"}, %{modal: :none} = state) do
    {:noreply, refresh_current(state)}
  end

  def handle_event(%Key{code: "d", kind: "press", modifiers: ["ctrl"]}, %{modal: :none} = state) do
    {:noreply, %{state | main_scroll: state.main_scroll + 10}}
  end

  def handle_event(%Key{code: "u", kind: "press", modifiers: ["ctrl"]}, %{modal: :none} = state) do
    {:noreply, %{state | main_scroll: max(state.main_scroll - 10, 0)}}
  end

  def handle_event(_, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_output, agent_id, data}, state) do
    outputs =
      Map.update(state.agent_outputs, agent_id, [data], fn buf ->
        Enum.take([data | buf], 500)
      end)

    {:noreply, %{state | agent_outputs: outputs}}
  end

  def handle_info({:agent_ready, agent_id}, state) do
    {:noreply, reload_sidebar(%{state | status: "Agent #{String.slice(agent_id, 0, 8)} ready"})}
  end

  def handle_info({:agent_stopped, agent_id, 0}, state) do
    {:noreply,
     reload_sidebar(%{state | status: "Agent #{String.slice(agent_id, 0, 8)} finished"})}
  end

  def handle_info({:agent_stopped, agent_id, code}, state) do
    {:noreply,
     reload_sidebar(%{
       state
       | status: "⚠ Agent #{String.slice(agent_id, 0, 8)} exited #{code} — see output pane"
     })}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    Enum.each(AgentSupervisor.list_agents(), &AgentSupervisor.stop_agent/1)
  end

  defp confirm_name(state) do
    name = String.trim(ExRatatui.text_input_get_value(state.modal_input))

    if name == "" do
      %{state | status: "Name cannot be empty"}
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

    case Store.create(name, [dir]) do
      {:ok, initiative} ->
        state
        |> reload_sidebar()
        |> then(fn s ->
          %{
            s
            | modal: :none,
              modal_context: nil,
              selected_initiative_id: initiative.id,
              status: "Created '#{name}'"
          }
        end)

      {:error, reason} ->
        %{state | modal: :none, modal_context: nil, status: "Create failed: #{inspect(reason)}"}
    end
  end

  defp confirm_dir(%{modal_context: {:add_dir, initiative_id}} = state) do
    dir = typed_dir(state)

    case Store.add_dir(initiative_id, dir) do
      {:ok, _} ->
        state
        |> reload_sidebar()
        |> then(fn s -> %{s | modal: :none, modal_context: nil, status: "Added: #{dir}"} end)

      {:error, reason} ->
        %{state | modal: :none, modal_context: nil, status: "Failed: #{inspect(reason)}"}
    end
  end

  defp confirm_dir(state), do: %{state | modal: :none, modal_context: nil}

  defp typed_dir(state) do
    state.modal_input |> ExRatatui.text_input_get_value() |> String.trim() |> Path.expand()
  end

  defp open_add_dir_modal(state) do
    initiative_id =
      case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
        {:initiative, id, _, _, _} -> id
        {:dir, id, _, _} -> id
        _ -> state.selected_initiative_id
      end

    if is_nil(initiative_id) do
      %{state | status: "Navigate to an initiative or directory first"}
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
      {:initiative, id, name, _, _} ->
        %{state | modal: :confirm_delete, modal_context: {:delete_initiative, id, name}}

      {:dir, initiative_id, dir, _} ->
        %{state | modal: :confirm_delete, modal_context: {:remove_dir, initiative_id, dir}}

      {:agent, agent_id, _, _} ->
        %{state | modal: :confirm_delete, modal_context: {:stop_agent, agent_id}}

      nil ->
        %{state | status: "Navigate to an item first"}
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
          %{
            s
            | modal: :none,
              modal_context: nil,
              selected_initiative_id: cleared,
              cursor_info: nil,
              status: "Deleted '#{name}'"
          }
        end)

      {:error, reason} ->
        %{state | modal: :none, modal_context: nil, status: "Delete failed: #{inspect(reason)}"}
    end
  end

  defp do_delete(%{modal_context: {:remove_dir, initiative_id, dir}} = state) do
    case Store.remove_dir(initiative_id, dir) do
      {:ok, _} ->
        state
        |> reload_sidebar()
        |> then(fn s ->
          %{s | modal: :none, modal_context: nil, cursor_info: nil, status: "Removed: #{dir}"}
        end)

      {:error, reason} ->
        %{state | modal: :none, modal_context: nil, status: "Failed: #{inspect(reason)}"}
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
          %{
            s
            | modal: :none,
              modal_context: nil,
              selected_agent_id: cleared,
              status: "Agent stopped"
          }
        end)

      {:error, :not_found} ->
        %{state | modal: :none, modal_context: nil, status: "Agent not found"}
    end
  end

  defp execute_palette_action(state) do
    filtered = Modals.filter_actions(state.actions, state.palette_filter)

    case Enum.at(filtered, state.palette_cursor) do
      nil ->
        %{state | modal: :none}

      %{id: :new_initiative} ->
        ExRatatui.text_input_set_value(state.modal_input, "")
        %{state | modal: :new_name}

      %{id: :add_dir} ->
        open_add_dir_modal(%{state | modal: :none})

      %{id: :start_claude} ->
        start_agent_at_cursor(%{state | modal: :none}, Codrift.Agent.Adapters.Claude)

      %{id: :start_aider} ->
        start_agent_at_cursor(%{state | modal: :none}, Codrift.Agent.Adapters.Aider)

      %{id: :delete_current} ->
        open_delete_confirm(%{state | modal: :none})

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
      max_idx = max(length(state.sidebar_entries) - 1, 0)
      new_cursor = min(max(state.sidebar_cursor + delta, 0), max_idx)

      %{state | sidebar_cursor: new_cursor, main_scroll: 0}
      |> update_context_from_cursor()
    else
      %{state | main_scroll: max(state.main_scroll + delta * 3, 0)}
    end
  end

  defp update_context_from_cursor(state) do
    case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
      {:initiative, id, _, _, _} -> fetch_initiative_context(state, id)
      {:dir, initiative_id, dir, _} -> fetch_dir_context(state, initiative_id, dir)
      {:agent, agent_id, _, _} -> maybe_subscribe_agent(state, agent_id)
      nil -> state
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

        cursor_info = %{
          type: :initiative,
          name: initiative.name,
          id: initiative.id,
          dirs: dir_infos
        }

        %{state | cursor_info: cursor_info, selected_initiative_id: initiative_id}

      {:error, :not_found} ->
        state
    end
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
    if state.selected_agent_id == agent_id do
      state
    else
      subscribe_to_agent(state, agent_id)
    end
  end

  defp subscribe_to_agent(state, agent_id) do
    case AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} ->
        AgentProcess.subscribe(pid)
        existing = pid |> AgentProcess.recent_output(200) |> Enum.reverse()
        short = String.slice(agent_id, 0, 8)

        %{
          state
          | selected_agent_id: agent_id,
            agent_outputs: Map.put(state.agent_outputs, agent_id, existing),
            status: "Subscribed to #{short}"
        }

      {:error, :not_found} ->
        %{state | status: "Agent #{agent_id} not found"}
    end
  end

  defp start_agent_at_cursor(state, adapter) do
    case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
      {:initiative, id, _, _, _} ->
        case Store.get(id) do
          {:ok, %{dirs: []}} -> %{state | status: "No directories — add one first (a)"}
          {:ok, %{dirs: [dir | _]}} -> do_start_agent(state, id, dir, adapter)
          {:error, :not_found} -> %{state | status: "Initiative not found"}
        end

      {:dir, initiative_id, dir, _} ->
        do_start_agent(state, initiative_id, dir, adapter)

      _ ->
        %{state | status: "Navigate to an initiative or directory to start an agent"}
    end
  end

  defp do_start_agent(state, initiative_id, dir, adapter) do
    case AgentSupervisor.start_agent(initiative_id, dir, adapter) do
      {:ok, _pid} -> reload_sidebar(%{state | status: "Agent started in #{compact_path(dir)}"})
      {:error, reason} -> %{state | status: "Failed: #{inspect(reason)}"}
    end
  end

  defp refresh_current(%{active_tab: :diff} = state), do: refresh_diff(state)
  defp refresh_current(state), do: update_context_from_cursor(state)

  defp refresh_diff(%{selected_initiative_id: nil} = state) do
    %{state | status: "Select an initiative first"}
  end

  defp refresh_diff(state) do
    case Store.get(state.selected_initiative_id) do
      {:ok, initiative} ->
        files = Enum.flat_map(initiative.dirs, &diff_for_dir/1)
        %{state | diff_files: files, status: "Diff: #{length(files)} file(s) changed"}

      {:error, :not_found} ->
        %{state | status: "Initiative not found"}
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
    agents = Enum.map(AgentSupervisor.list_agents(), &AgentProcess.status/1)
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
              %Span{content: " ● Context ", style: context_style},
              %Span{content: " │ ", style: %Style{fg: :dark_gray}},
              %Span{content: "2: Diff ", style: diff_style}
            ]
          }
        ]
      }
    }
  end

  defp render_main(%{active_tab: :diff} = state) do
    content =
      case state.diff_files do
        [] -> "No diff loaded.\n\nSelect an initiative and press '2' or 'r' to refresh."
        files -> Enum.map_join(files, "\n", &Diff.to_unified/1)
      end

    %CodeBlock{
      content: content,
      language: "diff",
      theme: :base16_ocean_dark,
      line_numbers: false,
      block: %Block{
        title: " Diff ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(state.focus, :main)
      },
      scroll: {state.main_scroll, 0}
    }
  end

  defp render_main(%{active_tab: :context} = state) do
    case Enum.at(state.sidebar_entries, state.sidebar_cursor) do
      {:initiative, _, name, _, _} -> render_initiative_pane(state, name)
      {:dir, _, dir, _} -> render_dir_pane(state, dir)
      {:agent, id, adapter, status} -> render_agent_pane(state, id, adapter, status)
      nil -> render_placeholder(state)
    end
  end

  defp render_initiative_pane(state, name) do
    text =
      case state.cursor_info do
        %{type: :initiative, dirs: dirs} ->
          Enum.map_join(dirs, "\n\n", &format_dir_info/1)

        _ ->
          "Loading…"
      end

    %Paragraph{
      text: text,
      block: %Block{
        title: " #{name} ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(state.focus, :main)
      },
      wrap: true,
      scroll: {state.main_scroll, 0}
    }
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
        title: " 📁 #{compact_path(dir)} ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(state.focus, :main)
      },
      wrap: true,
      scroll: {state.main_scroll, 0}
    }
  end

  defp render_agent_pane(state, agent_id, adapter, status) do
    text =
      case Map.get(state.agent_outputs, agent_id, []) do
        [] -> "(no output yet)\n\nSend a prompt: select this agent and type in the input pane."
        buf -> buf |> Enum.reverse() |> Enum.join()
      end

    adapter_name = adapter |> Module.split() |> List.last() |> String.downcase()
    title = " #{adapter_name} (#{status}) "

    %Paragraph{
      text: text,
      block: %Block{
        title: title,
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(state.focus, :main)
      },
      wrap: true,
      scroll: {state.main_scroll, 0}
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
        border_style: Styles.pane_border(state.focus, :main)
      },
      wrap: true
    }
  end

  defp render_footer(state) do
    %Paragraph{text: state.status, style: %Style{fg: :dark_gray}}
  end

  defp format_dir_info(%{path: path, branch: branch, last_commit: commit, agent_count: count}) do
    agents_label = if count == 0, do: "none", else: "#{count} running"

    "📁 #{compact_path(path)}\n" <>
      "   Branch:      #{branch}\n" <>
      "   Last commit: #{commit}\n" <>
      "   Agents:      #{agents_label}"
  end

  defp compact_path(path) do
    home = Path.expand("~")

    if String.starts_with?(path, home),
      do: "~" <> String.slice(path, String.length(home)..-1//1),
      else: path
  end
end

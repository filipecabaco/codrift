defmodule Codrift.TUI.Modals do
  @moduledoc """
  Modal overlay rendering for the Codrift TUI.

  Each modal is a list of `{widget, rect}` pairs rendered on top of the
  main layout. Delegates layout math to `Codrift.TUI.Layout`.
  """

  alias Codrift.Agent
  alias Codrift.Config.{Keybindings, Theme}
  alias Codrift.OAuth.Config, as: OAuthConfig
  alias Codrift.TUI.Layout
  alias ExRatatui.Layout, as: ExLayout

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Clear
  alias ExRatatui.Widgets.List, as: WidgetList
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.TextInput

  @type render_result :: [{term(), term()}]

  @doc """
  Returns `{widget, rect}` pairs for the active modal, or `[]` when no
  modal is open. Append the result to the base widget list in `render/2`.
  """
  def render(%{modal: %{type: :none}}, _frame), do: []
  def render(%{modal: %{type: :new_name}} = state, frame), do: new_name(state, frame)
  def render(%{modal: %{type: :new_dir}} = state, frame), do: new_dir(state, frame)
  def render(%{modal: %{type: :confirm_delete}} = state, frame), do: confirm_delete(state, frame)
  def render(%{modal: %{type: :palette}} = state, frame), do: palette(state, frame)
  def render(%{modal: %{type: :source_picker}} = state, frame), do: source_picker(state, frame)
  def render(%{modal: %{type: :service_setup}} = state, frame), do: service_setup(state, frame)

  def render(%{modal: %{type: :service_auth_url}} = state, frame),
    do: service_auth_url(state, frame)

  def render(%{modal: %{type: :service_device_flow}} = state, frame),
    do: service_device_flow(state, frame)

  def render(%{modal: %{type: :service_guided_token}} = state, frame),
    do: service_guided_token(state, frame)

  def render(%{modal: %{type: :integration_item_id}} = state, frame),
    do: integration_item_id(state, frame)

  def render(%{modal: %{type: :new_context_file}} = state, frame),
    do: new_context_file(state, frame)

  def render(%{modal: %{type: :theme_picker}} = state, frame), do: theme_picker(state, frame)

  def render(%{modal: %{type: :promote_name}} = state, frame),
    do: promote_name(state, frame)

  def render(%{modal: %{type: :agent_picker}} = state, frame), do: agent_picker(state, frame)
  def render(%{modal: %{type: :shortcuts}} = state, frame), do: shortcuts(state, frame)

  def render(%{modal: %{type: :orchestration_task}} = state, frame),
    do: orchestration_task(state, frame)

  @doc """
  Filters `actions` whose label contains `query` (case-insensitive).
  An empty query returns the full list unchanged.
  """
  def filter_actions(actions, ""), do: actions

  def filter_actions(actions, query) do
    q = String.downcase(query)
    Enum.filter(actions, fn %{label: label} -> String.contains?(String.downcase(label), q) end)
  end

  defp new_name(state, frame) do
    rect = Layout.center_rect(frame, 50, 7)
    inner = Layout.inset(rect, 1)

    [
      {%Clear{}, rect},
      {bordered(rect, " New Initiative ", :yellow), rect},
      {%Paragraph{text: "Name:", style: %Style{fg: :white}}, %{inner | height: 1}},
      {input(state.modal.input, "e.g. my-project"), %{inner | y: inner.y + 1, height: 1}},
      {hint("Enter: next  Esc: cancel"), %{inner | y: inner.y + 3, height: 1}}
    ]
  end

  defp promote_name(state, frame) do
    rect = Layout.center_rect(frame, 50, 7)
    inner = Layout.inset(rect, 1)

    [
      {%Clear{}, rect},
      {bordered(rect, " Promote Initiative ", :green), rect},
      {%Paragraph{text: "Name:", style: %Style{fg: :white}}, %{inner | height: 1}},
      {input(state.modal.input, "e.g. my-project"), %{inner | y: inner.y + 1, height: 1}},
      {hint("Enter: save  Esc: cancel"), %{inner | y: inner.y + 3, height: 1}}
    ]
  end

  defp new_dir(state, frame) do
    suggestions = state.modal.dir_picker.suggestions
    extra = if state.modal.worktree_git, do: 2, else: 0
    base_h = if suggestions == [], do: 7, else: min(4 + length(suggestions) + 1, 18)
    rect = Layout.center_rect(frame, 65, base_h + extra)
    inner = Layout.inset(rect, 1)
    title = dir_modal_title(state.modal.context)

    base = [
      {%Clear{}, rect},
      {bordered(rect, title, :yellow), rect},
      {input(state.modal.input, "~/projects/my-repo  (↑/↓ browse  Tab: descend)"),
       %{inner | height: 1}}
    ]

    base ++
      worktree_toggle_widgets(state.modal, inner) ++
      dir_picker_widgets(state.modal.dir_picker, inner, extra)
  end

  defp dir_modal_title({:creating, name}), do: " New Initiative: directory for '#{name}' "
  defp dir_modal_title(:add_dir), do: " Add Directory "
  defp dir_modal_title(_), do: " Directory "

  defp worktree_toggle_widgets(%{worktree_git: true, worktree_enabled: enabled}, inner) do
    toggle = if enabled, do: "[x]", else: "[ ]"
    style = if enabled, do: %Style{fg: :green}, else: %Style{fg: :dark_gray}

    [
      {%Paragraph{text: "#{toggle} Use git worktree  (w to toggle)", style: style},
       %{inner | y: inner.y + 2, height: 1}}
    ]
  end

  defp worktree_toggle_widgets(_, _inner), do: []

  defp dir_picker_widgets(%{suggestions: [], cursor: _}, inner, extra) do
    [{hint("Enter: confirm  Esc: cancel"), %{inner | y: inner.y + 3 + extra, height: 1}}]
  end

  defp dir_picker_widgets(%{suggestions: suggestions, cursor: cursor}, inner, extra) do
    items = Enum.map(suggestions, &"#{Path.basename(&1)}  #{Path.dirname(&1)}/")

    [
      {%WidgetList{
         items: items,
         selected: cursor,
         highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
         highlight_symbol: "▶ "
       }, %{inner | y: inner.y + 2 + extra, height: inner.height - 2 - extra}}
    ]
  end

  defp confirm_delete(%{modal: %{context: {:delete_initiative, _id, name}}}, frame) do
    rect = Layout.center_rect(frame, 52, 8)
    inner = Layout.inset(rect, 1)

    [
      {%Clear{}, rect},
      {bordered(rect, " Delete Initiative ", :red), rect},
      {%Paragraph{
         text:
           "Delete \"#{name}\"?\n\nThis removes the initiative from Codrift.\nRunning agents will be stopped.",
         style: %Style{fg: :white},
         wrap: true
       }, %{inner | height: 4}},
      {hint("Enter: confirm  Esc: cancel"), %{inner | y: inner.y + 5, height: 1}}
    ]
  end

  defp confirm_delete(%{modal: %{context: {:remove_dir, _initiative_id, dir}}}, frame) do
    rect = Layout.center_rect(frame, 60, 7)
    inner = Layout.inset(rect, 1)

    [
      {%Clear{}, rect},
      {bordered(rect, " Remove Directory ", :yellow), rect},
      {%Paragraph{
         text: "Remove this directory from the initiative?\n\n#{dir}",
         style: %Style{fg: :white},
         wrap: true
       }, %{inner | height: 3}},
      {hint("Enter: remove  Esc: cancel"), %{inner | y: inner.y + 4, height: 1}}
    ]
  end

  defp confirm_delete(%{modal: %{context: {:delete_context_file, _path, name}}}, frame) do
    rect = Layout.center_rect(frame, 52, 7)
    inner = Layout.inset(rect, 1)

    [
      {%Clear{}, rect},
      {bordered(rect, " Delete File ", :red), rect},
      {%Paragraph{
         text: "Delete \"#{name}\"?\n\nThis file will be permanently removed.",
         style: %Style{fg: :white},
         wrap: true
       }, %{inner | height: 3}},
      {hint("Enter: delete  Esc: cancel"), %{inner | y: inner.y + 4, height: 1}}
    ]
  end

  defp confirm_delete(%{modal: %{context: {:stop_agent, agent_id}}}, frame) do
    rect = Layout.center_rect(frame, 52, 7)
    inner = Layout.inset(rect, 1)
    short = String.slice(agent_id, 0, 12)

    [
      {%Clear{}, rect},
      {bordered(rect, " Stop Agent ", :yellow), rect},
      {%Paragraph{
         text: "Stop agent #{short}…?\n\nThe process will be terminated.",
         style: %Style{fg: :white},
         wrap: true
       }, %{inner | height: 3}},
      {hint("Enter: stop  Esc: cancel"), %{inner | y: inner.y + 4, height: 1}}
    ]
  end

  defp palette(state, frame) do
    filtered = filter_actions(state.modal.actions, state.modal.palette.filter)
    height = min(length(filtered) + 5, 20)
    rect = Layout.center_rect(frame, 60, height)
    inner = Layout.inset(rect, 1)

    items =
      Enum.map(filtered, fn %{label: label, hint: keybinding} ->
        if keybinding == "", do: label, else: "#{label}  (#{keybinding})"
      end)

    [
      {%Clear{}, rect},
      {bordered(rect, " Command Palette ", :yellow), rect},
      {input(state.modal.input, "Type to filter…"), %{inner | height: 1}},
      {%WidgetList{
         items: items,
         selected: state.modal.palette.cursor,
         highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
         highlight_symbol: "▶ "
       }, %{inner | y: inner.y + 2, height: max(inner.height - 2, 1)}}
    ]
  end

  defp new_context_file(state, frame) do
    ctx_dir =
      case state.modal.context do
        {:new_context_file, path} -> path
        _ -> "context folder"
      end

    rect = Layout.center_rect(frame, 60, 8)
    inner = Layout.inset(rect, 1)

    [
      {%Clear{}, rect},
      {bordered(rect, " New Context File ", :blue), rect},
      {%Paragraph{
         text: "Folder: #{ctx_dir}",
         style: %Style{fg: :dark_gray}
       }, %{inner | height: 1}},
      {%Paragraph{text: "Filename:", style: %Style{fg: :white}},
       %{inner | y: inner.y + 2, height: 1}},
      {input(state.modal.input, "e.g. README.md  plan.md  context.txt"),
       %{inner | y: inner.y + 3, height: 1}},
      {hint("Enter: create  Esc: cancel"), %{inner | y: inner.y + 5, height: 1}}
    ]
  end

  defp agent_picker(state, frame) do
    adapters = state.modal.context
    height = min(length(adapters) + 4, 15)
    rect = Layout.center_rect(frame, 40, height)
    inner = Layout.inset(rect, 1)

    items = Enum.map(adapters, &Agent.adapter_name/1)

    [
      {%Clear{}, rect},
      {bordered(rect, " Start Agent ", :green), rect},
      {%WidgetList{
         items: items,
         selected: state.modal.agent_picker.cursor,
         highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
         highlight_symbol: "▶ "
       }, %{inner | height: max(inner.height - 1, 1)}},
      {hint("Enter: start  Esc: cancel"), %{inner | y: inner.y + inner.height - 1, height: 1}}
    ]
  end

  defp theme_picker(state, frame) do
    themes = Theme.all() |> Enum.sort_by(fn {name, _} -> name end)
    height = length(themes) + 4
    rect = Layout.center_rect(frame, 40, height)
    inner = Layout.inset(rect, 1)

    items =
      Enum.map(themes, fn {_name, theme} ->
        marker = if theme.name == state.modal.theme_picker.before.name, do: " ●", else: "  "
        "#{marker} #{theme.name}"
      end)

    [
      {%Clear{}, rect},
      {bordered(rect, " Choose Theme ", :yellow), rect},
      {%WidgetList{
         items: items,
         selected: state.modal.theme_picker.cursor,
         highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
         highlight_symbol: "▶ "
       }, %{inner | height: max(inner.height - 1, 1)}},
      {hint("Enter: apply  Esc: cancel"), %{inner | y: inner.y + inner.height - 1, height: 1}}
    ]
  end

  @sources [
    {"new", "Blank initiative"},
    {"github", "GitHub Issues"},
    {"github_projects", "GitHub Projects v2"},
    {"linear", "Linear Issues"},
    {"linear_projects", "Linear Projects"},
    {"gitlab", "GitLab Issues"},
    {"jira", "Jira Cloud"},
    {"notion", "Notion"}
  ]

  @doc "Returns `{service_key, label}` pairs for the source picker list."
  def sources, do: @sources

  defp source_picker(state, frame) do
    height = length(@sources) + 4
    rect = Layout.center_rect(frame, 58, height)
    inner = Layout.inset(rect, 1)

    items =
      Enum.map(@sources, fn {key, label} ->
        "#{source_status(key)}#{String.pad_trailing(key, 18)} #{label}"
      end)

    [
      {%Clear{}, rect},
      {bordered(rect, " Initiative Source ", :yellow), rect},
      {%WidgetList{
         items: items,
         selected: state.modal.source_picker.cursor,
         highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
         highlight_symbol: "▶ "
       }, %{inner | height: max(inner.height - 1, 1)}},
      {hint("↑/↓: choose  Enter: confirm  Esc: cancel"),
       %{inner | y: inner.y + inner.height - 1, height: 1}}
    ]
  end

  # ── Service setup ─────────────────────────────────────────────────────────

  @doc "Returns the list of services shown in the setup modal."
  def setup_services do
    Codrift.Integration.adapters()
    |> Enum.map(& &1.name())
  end

  defp service_setup(state, frame) do
    services = setup_services()
    height = length(services) + 5
    rect = Layout.center_rect(frame, 62, height)
    inner = Layout.inset(rect, 1)

    items =
      Enum.map(services, fn svc ->
        connected = Codrift.OAuth.connected?(svc)
        dot = if connected, do: "●", else: "○"
        status_label = if connected, do: "connected   ", else: "not connected"
        auth = auth_type_label(svc)
        "#{dot} #{String.pad_trailing(svc, 18)} #{String.pad_trailing(status_label, 14)} #{auth}"
      end)

    [
      {%Clear{}, rect},
      {bordered(rect, " Integrations ", :cyan), rect},
      {%WidgetList{
         items: items,
         selected: state.modal.service_setup.cursor,
         highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
         highlight_symbol: "▶ "
       }, %{inner | height: max(inner.height - 2, 1)}},
      {hint("Enter: connect  r: revoke  Esc: close"),
       %{inner | y: inner.y + inner.height - 1, height: 1}}
    ]
  end

  defp service_auth_url(state, frame) do
    {service, url} =
      case state.modal.context do
        {:connecting_for_import, svc, url} -> {svc, url}
        {:connecting_standalone, svc, url} -> {svc, url}
        _ -> {"service", ""}
      end

    # Wrap the URL across two lines if needed
    {url_line1, url_line2} =
      if String.length(url) <= 56 do
        {url, ""}
      else
        {String.slice(url, 0, 56), String.slice(url, 56..-1//1)}
      end

    has_second = url_line2 != ""
    height = if has_second, do: 11, else: 10
    rect = Layout.center_rect(frame, 62, height)
    inner = Layout.inset(rect, 1)

    widgets = [
      {%Clear{}, rect},
      {bordered(rect, " Connect #{service} ", :cyan), rect},
      {%Paragraph{text: "Open this URL in your browser:", style: %Style{fg: :white}},
       %{inner | height: 1}},
      {%Paragraph{text: url_line1, style: %Style{fg: :cyan}},
       %{inner | y: inner.y + 2, height: 1}}
    ]

    widgets =
      if has_second do
        widgets ++
          [
            {%Paragraph{text: url_line2, style: %Style{fg: :cyan}},
             %{inner | y: inner.y + 3, height: 1}}
          ]
      else
        widgets
      end

    note_y = if has_second, do: inner.y + 5, else: inner.y + 4
    hint_y = note_y + 2

    widgets ++
      [
        {%Paragraph{
           text: "The Codrift server captures the callback automatically.",
           style: %Style{fg: :dark_gray},
           wrap: true
         }, %{inner | y: note_y, height: 2}},
        {hint("Enter: check connection  Esc: cancel"), %{inner | y: hint_y, height: 1}}
      ]
  end

  defp service_guided_token(state, frame) do
    {service, instructions} =
      case state.modal.context do
        {:connecting_for_import, svc, inst} -> {svc, inst}
        {:connecting_standalone, svc, inst} -> {svc, inst}
        _ -> {"service", "Follow the service instructions."}
      end

    lines = instructions |> String.trim() |> String.split("\n")
    inst_height = length(lines)
    height = inst_height + 7
    rect = Layout.center_rect(frame, 66, height)
    inner = Layout.inset(rect, 1)

    [
      {%Clear{}, rect},
      {bordered(rect, " Connect #{service} ", :cyan), rect},
      {%Paragraph{
         text: String.trim(instructions),
         style: %Style{fg: :white},
         wrap: true
       }, %{inner | height: inst_height}},
      {%Paragraph{text: "Token:", style: %Style{fg: :white}},
       %{inner | y: inner.y + inst_height + 1, height: 1}},
      {input(state.modal.input, "paste token here"),
       %{inner | y: inner.y + inst_height + 2, height: 1}},
      {hint("Enter: save  Esc: cancel"), %{inner | y: inner.y + inst_height + 4, height: 1}}
    ]
  end

  defp service_device_flow(state, frame) do
    {service, user_code, verification_uri} =
      case state.modal.context do
        {:connecting_for_import, svc, code, uri} -> {svc, code, uri}
        {:connecting_standalone, svc, code, uri} -> {svc, code, uri}
        _ -> {"service", "XXXX-XXXX", "https://github.com/login/device"}
      end

    rect = Layout.center_rect(frame, 58, 10)
    inner = Layout.inset(rect, 1)

    [
      {%Clear{}, rect},
      {bordered(rect, " Connect #{service} ", :cyan), rect},
      {%Paragraph{text: "1. Open #{verification_uri} in your browser", style: %Style{fg: :white}},
       %{inner | height: 1}},
      {%Paragraph{text: "2. Enter this code when prompted:", style: %Style{fg: :white}},
       %{inner | y: inner.y + 2, height: 1}},
      {%Paragraph{text: "   #{user_code}", style: %Style{fg: :cyan, modifiers: [:bold]}},
       %{inner | y: inner.y + 3, height: 1}},
      {%Paragraph{
         text: "Checking in background — this will close automatically.",
         style: %Style{fg: :dark_gray}
       }, %{inner | y: inner.y + 5, height: 1}},
      {hint("Esc: cancel"), %{inner | y: inner.y + 7, height: 1}}
    ]
  end

  defp auth_type_label(svc) do
    case OAuthConfig.get(svc) do
      {:ok, %{flow: :pkce_browser}} -> "pkce"
      {:ok, %{flow: :device_flow}} -> "device flow"
      {:ok, %{flow: :guided_token}} -> "guided token"
      _ -> "env var"
    end
  end

  defp integration_item_id(state, frame) do
    {service, item_hint} =
      case state.modal.context do
        {:importing, _name, svc} -> {svc, item_id_hint(svc)}
        _ -> {"service", "item ID"}
      end

    rect = Layout.center_rect(frame, 60, 8)
    inner = Layout.inset(rect, 1)

    [
      {%Clear{}, rect},
      {bordered(rect, " Import from #{service} ", :cyan), rect},
      {%Paragraph{text: "Item ID:", style: %Style{fg: :white}}, %{inner | height: 1}},
      {input(state.modal.input, item_hint), %{inner | y: inner.y + 1, height: 1}},
      {hint("Enter: import  Esc: cancel"), %{inner | y: inner.y + 5, height: 1}}
    ]
  end

  defp item_id_hint("github"), do: "owner/repo#123"
  defp item_id_hint("github_projects"), do: "node ID (from list)"
  defp item_id_hint("linear"), do: "ENG-123 or UUID"
  defp item_id_hint("linear_projects"), do: "project UUID"
  defp item_id_hint("gitlab"), do: "group/project#42"
  defp item_id_hint("jira"), do: "ENG-42"
  defp item_id_hint("notion"), do: "page UUID (32 chars)"
  defp item_id_hint("shortcut"), do: "story public ID, e.g. 1234"
  defp item_id_hint(_), do: "item ID"

  defp source_status("new"), do: "  "
  defp source_status(svc), do: if(Codrift.OAuth.connected?(svc), do: "● ", else: "○ ")

  defp bordered(_rect, title, color) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: color}
    }
  end

  defp input(ref, placeholder) do
    %TextInput{
      state: ref,
      placeholder: placeholder,
      placeholder_style: %Style{fg: :dark_gray},
      style: %Style{fg: :white},
      cursor_style: %Style{modifiers: [:reversed]}
    }
  end

  defp hint(text), do: %Paragraph{text: text, style: %Style{fg: :dark_gray}}

  # ── Shortcuts modal ───────────────────────────────────────────────────────────

  defp shortcuts(state, frame) do
    kb = state.kb.bindings
    rect = Layout.center_rect(frame, 76, 24)
    inner = Layout.inset(rect, 1)

    [left_rect, right_rect] =
      ExLayout.split(inner, :horizontal, [{:percentage, 50}, {:percentage, 50}])

    hint_rect = %{inner | y: inner.y + inner.height - 1, height: 1}

    [
      {%Clear{}, rect},
      {bordered(rect, " Keyboard Shortcuts ", :cyan), rect},
      {shortcuts_left(kb), %{left_rect | height: left_rect.height - 1}},
      {shortcuts_right(kb), %{right_rect | height: right_rect.height - 1}},
      {hint("Esc / Enter: close"), hint_rect}
    ]
  end

  defp shortcuts_left(kb) do
    %Paragraph{
      text: %ExRatatui.Text{
        lines:
          section("GLOBAL") ++
            row(kb.navigate_down, "navigate down") ++
            row(kb.navigate_up, "navigate up") ++
            row(kb.palette, "command palette") ++
            row(kb.toggle_sidebar, "toggle sidebar") ++
            row("ctrl+d / ctrl+u", "scroll half page") ++
            row(kb.quit, "quit") ++
            [blank()] ++
            section("AGENTS & CONTEXT") ++
            row(kb.new_initiative, "new initiative") ++
            row(kb.add_dir, "add directory") ++
            row(kb.start_agent, "start agent") ++
            row(kb.start_orchestration, "start orchestration") ++
            row(kb.delete, "delete / stop") ++
            row("#{kb.status_prev}/#{kb.status_next}", "cycle status") ++
            row(kb.new_context, "new context file") ++
            row(kb.edit_context, "edit / open file")
      }
    }
  end

  defp shortcuts_right(kb) do
    %Paragraph{
      text: %ExRatatui.Text{
        lines:
          section("DIFF") ++
            row("/", "filter files") ++
            row("Esc", "clear filter") ++
            row(kb.toggle_diff_view, "unified / split") ++
            row(kb.diff_all_files, "show all files") ++
            row(kb.refresh, "refresh diff") ++
            [blank()] ++
            section("TREE") ++
            row("/", "filter files") ++
            row("Esc", "clear filter") ++
            row("Enter / Spc", "expand / collapse") ++
            row("→ / ←", "expand / collapse") ++
            row(kb.edit_context, "open in editor") ++
            row(kb.new_initiative, "new file or dir") ++
            row(kb.delete, "delete") ++
            [blank()] ++
            section("PTY") ++
            row(kb.start_terminal, "open terminal") ++
            row("?", "show this pane")
      }
    }
  end

  defp orchestration_task(state, frame) do
    rect = Layout.center_rect(frame, 60, 10)
    inner = Layout.inset(rect, 1)

    initiative_id =
      case state.modal.context do
        %{initiative_id: id} -> id
        _ -> ""
      end

    [
      {%Clear{}, rect},
      {bordered(rect, " Start Orchestration ", :magenta), rect},
      {%Paragraph{
         text: "Initiative: #{initiative_id}",
         style: %Style{fg: :dark_gray}
       }, %{inner | height: 1}},
      {%Paragraph{text: "Task:", style: %Style{fg: :white}},
       %{inner | y: inner.y + 2, height: 1}},
      {input(state.modal.input, "Defaults to initiative.md — edit to override"),
       %{inner | y: inner.y + 3, height: 1}},
      {%Paragraph{
         text: "Pre-filled from initiative.md. Edit to override, or press Enter to start.",
         style: %Style{fg: :dark_gray},
         wrap: true
       }, %{inner | y: inner.y + 5, height: 2}},
      {hint("Enter: start  Esc: cancel"), %{inner | y: inner.y + 8, height: 1}}
    ]
  end

  defp section(title) do
    [
      %Line{
        spans: [%Span{content: " #{title}", style: %Style{fg: :cyan, modifiers: [:bold]}}]
      }
    ]
  end

  defp row(key, desc) do
    key_str = Keybindings.format(key)
    padded = String.pad_trailing("  #{key_str}", 16)

    [
      %Line{
        spans: [
          %Span{content: padded, style: %Style{fg: :yellow}},
          %Span{content: desc, style: %Style{fg: :white}}
        ]
      }
    ]
  end

  defp blank, do: %Line{spans: [%Span{content: ""}]}
end

defmodule Codrift.TUI.Modals do
  @moduledoc """
  Modal overlay rendering for the Codrift TUI.

  Each modal is a list of `{widget, rect}` pairs rendered on top of the
  main layout. Delegates layout math to `Codrift.TUI.Layout`.
  """

  alias Codrift.Config.Theme
  alias Codrift.OAuth.Config, as: OAuthConfig
  alias Codrift.TUI.Layout

  alias ExRatatui.Style
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

  defp new_dir(state, frame) do
    suggestions = state.modal.dir_picker.suggestions
    total_height = if suggestions == [], do: 7, else: min(4 + length(suggestions) + 1, 18)
    rect = Layout.center_rect(frame, 65, total_height)
    inner = Layout.inset(rect, 1)

    title =
      case state.modal.context do
        {:creating, name} -> " New Initiative: directory for '#{name}' "
        :add_dir -> " Add Directory "
        _ -> " Directory "
      end

    base = [
      {%Clear{}, rect},
      {bordered(rect, title, :yellow), rect},
      {input(state.modal.input, "~/projects/my-repo  (↑/↓ browse  Tab: descend)"),
       %{inner | height: 1}}
    ]

    if suggestions == [] do
      base ++ [{hint("Enter: confirm  Esc: cancel"), %{inner | y: inner.y + 3, height: 1}}]
    else
      items =
        Enum.map(suggestions, fn path -> "#{Path.basename(path)}  #{Path.dirname(path)}/" end)

      base ++
        [
          {%WidgetList{
             items: items,
             selected: state.modal.dir_picker.cursor,
             highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
             highlight_symbol: "▶ "
           }, %{inner | y: inner.y + 2, height: inner.height - 2}}
        ]
    end
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
end

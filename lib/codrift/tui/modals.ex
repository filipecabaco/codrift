defmodule Codrift.TUI.Modals do
  @moduledoc """
  Modal overlay rendering for the Codrift TUI.

  Each modal is a list of `{widget, rect}` pairs rendered on top of the
  main layout. Delegates layout math to `Codrift.TUI.Layout`.
  """

  alias ExRatatui.Style
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Clear
  alias ExRatatui.Widgets.List, as: WidgetList
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.TextInput
  alias Codrift.TUI.Layout

  @type render_result :: [{term(), term()}]

  @doc """
  Returns `{widget, rect}` pairs for the active modal, or `[]` when no
  modal is open. Append the result to the base widget list in `render/2`.
  """
  def render(%{modal: :none}, _frame), do: []
  def render(%{modal: :new_name} = state, frame), do: new_name(state, frame)
  def render(%{modal: :new_dir} = state, frame), do: new_dir(state, frame)
  def render(%{modal: :confirm_delete} = state, frame), do: confirm_delete(state, frame)
  def render(%{modal: :palette} = state, frame), do: palette(state, frame)
  def render(%{modal: :new_context_file} = state, frame), do: new_context_file(state, frame)
  def render(%{modal: :theme_picker} = state, frame), do: theme_picker(state, frame)

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
      {input(state.modal_input, "e.g. my-project"), %{inner | y: inner.y + 1, height: 1}},
      {hint("Enter: next  Esc: cancel"), %{inner | y: inner.y + 3, height: 1}}
    ]
  end

  defp new_dir(state, frame) do
    suggestions = state.dir_suggestions
    total_height = if suggestions == [], do: 7, else: min(4 + length(suggestions) + 1, 18)
    rect = Layout.center_rect(frame, 65, total_height)
    inner = Layout.inset(rect, 1)

    title =
      case state.modal_context do
        {:creating, name} -> " New Initiative: directory for '#{name}' "
        :add_dir -> " Add Directory "
        _ -> " Directory "
      end

    base = [
      {%Clear{}, rect},
      {bordered(rect, title, :yellow), rect},
      {input(state.modal_input, "~/projects/my-repo  (↑/↓ browse  Tab: descend)"),
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
             selected: state.dir_suggestion_cursor,
             highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
             highlight_symbol: "▶ "
           }, %{inner | y: inner.y + 2, height: inner.height - 2}}
        ]
    end
  end

  defp confirm_delete(%{modal_context: {:delete_initiative, _id, name}}, frame) do
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

  defp confirm_delete(%{modal_context: {:remove_dir, _initiative_id, dir}}, frame) do
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

  defp confirm_delete(%{modal_context: {:delete_context_file, _path, name}}, frame) do
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

  defp confirm_delete(%{modal_context: {:stop_agent, agent_id}}, frame) do
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
    filtered = filter_actions(state.actions, state.palette_filter)
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
      {input(state.modal_input, "Type to filter…"), %{inner | height: 1}},
      {%WidgetList{
         items: items,
         selected: state.palette_cursor,
         highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
         highlight_symbol: "▶ "
       }, %{inner | y: inner.y + 2, height: max(inner.height - 2, 1)}}
    ]
  end

  defp new_context_file(state, frame) do
    ctx_dir =
      case state.modal_context do
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
      {input(state.modal_input, "e.g. README.md  plan.md  context.txt"),
       %{inner | y: inner.y + 3, height: 1}},
      {hint("Enter: create  Esc: cancel"), %{inner | y: inner.y + 5, height: 1}}
    ]
  end

  defp theme_picker(state, frame) do
    themes = Codrift.Config.Theme.all() |> Enum.sort_by(fn {name, _} -> name end)
    height = length(themes) + 4
    rect = Layout.center_rect(frame, 40, height)
    inner = Layout.inset(rect, 1)

    items =
      Enum.map(themes, fn {_name, theme} ->
        marker = if theme.name == state.theme_before_picker.name, do: " ●", else: "  "
        "#{marker} #{theme.name}"
      end)

    [
      {%Clear{}, rect},
      {bordered(rect, " Choose Theme ", :yellow), rect},
      {%WidgetList{
         items: items,
         selected: state.theme_picker_cursor,
         highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
         highlight_symbol: "▶ "
       }, %{inner | height: max(inner.height - 1, 1)}},
      {hint("Enter: apply  Esc: cancel"), %{inner | y: inner.y + inner.height - 1, height: 1}}
    ]
  end

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

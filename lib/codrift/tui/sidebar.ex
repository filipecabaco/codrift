defmodule Codrift.TUI.Sidebar do
  @moduledoc """
  Sidebar entry building and rendering for the Codrift TUI.

  ## Entry hierarchy

      {:initiative, id, name, dir_count, agent_count}
        {:dir, initiative_id, path, agent_count}
          {:agent, id, adapter, status}
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.List, as: WidgetList
  alias Codrift.TUI.Styles

  @type entry ::
          {:initiative, id :: String.t(), name :: String.t(), dir_count :: non_neg_integer(),
           agent_count :: non_neg_integer()}
          | {:dir, initiative_id :: String.t(), path :: String.t(),
             agent_count :: non_neg_integer()}
          | {:agent, id :: String.t(), adapter :: module(), status :: atom()}

  @doc """
  Builds a flat list of sidebar entries from `%Initiative{}` structs and
  agent status maps, grouped as initiative → dir → agent.
  """
  def build_entries(initiatives, agents) do
    by_initiative = Enum.group_by(agents, & &1.initiative_id)

    Enum.flat_map(initiatives, fn initiative ->
      initiative_agents = Map.get(by_initiative, initiative.id, [])
      by_dir = Enum.group_by(initiative_agents, & &1.dir)

      header =
        {:initiative, initiative.id, initiative.name, length(initiative.dirs),
         length(initiative_agents)}

      dir_rows = Enum.flat_map(initiative.dirs, &dir_entries(initiative.id, &1, by_dir))

      [header | dir_rows]
    end)
  end

  defp dir_entries(initiative_id, dir, by_dir) do
    dir_agents = Map.get(by_dir, dir, [])
    header = {:dir, initiative_id, dir, length(dir_agents)}
    rows = Enum.map(dir_agents, fn a -> {:agent, a.id, a.adapter, a.status} end)
    [header | rows]
  end

  @doc "Renders the sidebar `%WidgetList{}` widget."
  def render(entries, cursor, focus) do
    %WidgetList{
      items: Enum.map(entries, &item/1),
      selected: cursor,
      block: %Block{
        title: " Initiatives ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(focus, :sidebar)
      },
      highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
      highlight_symbol: "▶ "
    }
  end

  defp item({:initiative, _id, name, _dirs, 0}) do
    %Line{
      spans: [
        %Span{content: "○ ", style: %Style{fg: :dark_gray}},
        %Span{content: name, style: %Style{modifiers: [:bold]}}
      ]
    }
  end

  defp item({:initiative, _id, name, _dirs, count}) do
    %Line{
      spans: [
        %Span{content: "● ", style: %Style{fg: :green}},
        %Span{content: name, style: %Style{modifiers: [:bold]}},
        %Span{content: " [#{count}]", style: %Style{fg: :dark_gray}}
      ]
    }
  end

  defp item({:dir, _initiative_id, path, 0}) do
    %Line{
      spans: [
        %Span{content: "  📁 ", style: %Style{fg: :dark_gray}},
        %Span{content: compact_path(path), style: %Style{fg: :dark_gray}}
      ]
    }
  end

  defp item({:dir, _initiative_id, path, count}) do
    %Line{
      spans: [
        %Span{content: "  📁 ", style: %Style{fg: :cyan}},
        %Span{content: compact_path(path), style: %Style{fg: :white}},
        %Span{content: " [#{count}]", style: %Style{fg: :dark_gray}}
      ]
    }
  end

  defp item({:agent, _id, adapter, status}) do
    color = Styles.status_color(status)
    name = adapter |> Module.split() |> List.last() |> String.downcase()

    %Line{
      spans: [
        %Span{content: "    ◦ ", style: %Style{fg: color}},
        %Span{content: name, style: %Style{fg: :white}},
        %Span{content: " (#{format_status(status)})", style: %Style{fg: color}}
      ]
    }
  end

  defp format_status(:awaiting_input), do: "ready"
  defp format_status(:starting), do: "starting"
  defp format_status(:running), do: "running"
  defp format_status(:idle), do: "idle"
  defp format_status(:stopped), do: "stopped"
  defp format_status(other), do: to_string(other)

  defp compact_path(path) do
    home = Path.expand("~")

    if String.starts_with?(path, home) do
      "~" <> String.slice(path, String.length(home)..-1//1)
    else
      path
    end
  end
end

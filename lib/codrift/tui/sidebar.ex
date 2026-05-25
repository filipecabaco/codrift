defmodule Codrift.TUI.Sidebar do
  @moduledoc """
  Sidebar entry building and rendering for the Codrift TUI.

  ## Entry hierarchy

      {:initiative, id, name, dir_count, agent_count, status}
        {:context_dir, initiative_id, path, agent_count}
          {:context_file, initiative_id, full_path, filename}
          {:agent, id, adapter, status}
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
           agent_count :: non_neg_integer(), status :: atom()}
          | {:context_dir, initiative_id :: String.t(), path :: String.t(),
             agent_count :: non_neg_integer()}
          | {:context_file, initiative_id :: String.t(), full_path :: String.t(),
             filename :: String.t()}
          | {:dir, initiative_id :: String.t(), path :: String.t(),
             agent_count :: non_neg_integer()}
          | {:agent, id :: String.t(), adapter :: module(), status :: atom()}

  @doc """
  Builds a flat list of sidebar entries from `%Initiative{}` structs and
  agent status maps, grouped as initiative → context → dir → agent.
  """
  def build_entries(initiatives, agents) do
    by_initiative = Enum.group_by(agents, & &1.initiative_id)

    Enum.flat_map(initiatives, fn initiative ->
      initiative_agents = Map.get(by_initiative, initiative.id, [])
      by_dir = Enum.group_by(initiative_agents, & &1.dir)

      header =
        {:initiative, initiative.id, initiative.name, length(initiative.dirs),
         length(initiative_agents), initiative.status || :ongoing}

      ctx_path = Codrift.Initiative.Store.context_path(initiative.id)
      context_rows = context_dir_entries(initiative.id, ctx_path, by_dir)
      dir_rows = Enum.flat_map(initiative.dirs, &dir_entries(initiative.id, &1, by_dir))

      [header | context_rows ++ dir_rows]
    end)
  end

  defp context_dir_entries(initiative_id, path, by_dir) do
    dir_agents = Map.get(by_dir, path, [])

    files =
      case File.ls(path) do
        {:ok, fs} -> fs |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
        {:error, _} -> []
      end

    header = {:context_dir, initiative_id, path, length(dir_agents)}
    file_rows = Enum.map(files, fn f -> {:context_file, initiative_id, Path.join(path, f), f} end)
    agent_rows = Enum.map(dir_agents, fn a -> {:agent, a.id, a.adapter, a.status} end)
    [header | file_rows ++ agent_rows]
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

  # Initiative with no running agents — show status icon only
  defp item({:initiative, _id, name, _dirs, 0, status}) do
    {icon, color} = status_display(status)

    %Line{
      spans: [
        %Span{content: "#{icon} ", style: %Style{fg: color}},
        %Span{content: name, style: %Style{modifiers: [:bold]}},
        %Span{content: " [#{status}]", style: %Style{fg: color}}
      ]
    }
  end

  # Initiative with running agents — show agent count
  defp item({:initiative, _id, name, _dirs, count, status}) do
    {icon, color} = status_display(status)

    %Line{
      spans: [
        %Span{content: "#{icon} ", style: %Style{fg: color}},
        %Span{content: name, style: %Style{modifiers: [:bold]}},
        %Span{content: " [#{count}]", style: %Style{fg: :green}}
      ]
    }
  end

  defp item({:context_dir, _initiative_id, _path, 0}) do
    %Line{
      spans: [
        %Span{content: "  ◈ ", style: %Style{fg: :blue}},
        %Span{content: "context", style: %Style{fg: :blue}}
      ]
    }
  end

  defp item({:context_dir, _initiative_id, _path, count}) do
    %Line{
      spans: [
        %Span{content: "  ◈ ", style: %Style{fg: :blue}},
        %Span{content: "context", style: %Style{fg: :blue}},
        %Span{content: " [#{count}]", style: %Style{fg: :green}}
      ]
    }
  end

  defp item({:context_file, _initiative_id, _path, name}) do
    %Line{
      spans: [
        %Span{content: "    – ", style: %Style{fg: :dark_gray}},
        %Span{content: name, style: %Style{fg: :white}}
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
        %Span{content: " (#{format_agent_status(status)})", style: %Style{fg: color}}
      ]
    }
  end

  defp status_display(:planning), do: {"◷", :blue}
  defp status_display(:ongoing), do: {"●", :green}
  defp status_display(:done), do: {"✓", :cyan}
  defp status_display(:archived), do: {"○", :dark_gray}
  defp status_display(_), do: {"○", :dark_gray}

  defp format_agent_status(:awaiting_input), do: "ready"
  defp format_agent_status(:starting), do: "starting"
  defp format_agent_status(:running), do: "running"
  defp format_agent_status(:idle), do: "idle"
  defp format_agent_status(:stopped), do: "stopped"
  defp format_agent_status(other), do: to_string(other)

  defp compact_path(path) do
    home = Path.expand("~")

    if String.starts_with?(path, home) do
      "~" <> String.slice(path, String.length(home)..-1//1)
    else
      path
    end
  end
end

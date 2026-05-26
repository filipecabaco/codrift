defmodule Codrift.TUI.Sidebar do
  @moduledoc """
  Sidebar entry building and rendering for the Codrift TUI.

  ## Context mode entry hierarchy

      {:initiative, id, name, dir_count, agent_count, status}
        {:context_dir, initiative_id, path, agent_count}
          {:context_file, initiative_id, full_path, filename}
          {:agent, id, adapter, status}
        {:dir, initiative_id, path, agent_count}
          {:agent, id, adapter, status}

  ## Diff mode entry hierarchy

      {:diff_all, total_adds, total_dels}
        {:diff_dir, dir, adds, dels}
          {:diff_file, dir, path, adds, dels}
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
          | {:diff_all, total_adds :: non_neg_integer(), total_dels :: non_neg_integer()}
          | {:diff_dir, dir :: String.t(), adds :: non_neg_integer(), dels :: non_neg_integer()}
          | {:diff_file, dir :: String.t(), path :: String.t(), adds :: non_neg_integer(),
             dels :: non_neg_integer()}

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
        {:ok, fs} ->
          fs
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.reject(&(&1 == "CLAUDE.md"))
          |> Enum.sort()

        {:error, _} ->
          []
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

  @doc """
  Builds a flat list of sidebar entries for the diff tab.

  `dir_diffs` is a list of `{dir, [%FileDiff{}]}` pairs (one per initiative directory).
  Directories with no changed files are excluded. The first entry is always
  `{:diff_all, total_adds, total_dels}`; it is followed by per-dir and per-file entries.
  """
  def build_diff_entries(dir_diffs) when is_list(dir_diffs) do
    nonempty = Enum.filter(dir_diffs, fn {_, files} -> files != [] end)

    if nonempty == [] do
      [{:diff_all, 0, 0}]
    else
      all_files = Enum.flat_map(nonempty, fn {_, fs} -> fs end)
      total_adds = Enum.sum(Enum.map(all_files, & &1.additions))
      total_dels = Enum.sum(Enum.map(all_files, & &1.deletions))

      dir_rows =
        Enum.flat_map(nonempty, fn {dir, files} ->
          dir_adds = Enum.sum(Enum.map(files, & &1.additions))
          dir_dels = Enum.sum(Enum.map(files, & &1.deletions))

          file_rows =
            Enum.map(files, fn f -> {:diff_file, dir, f.path, f.additions, f.deletions} end)

          [{:diff_dir, dir, dir_adds, dir_dels} | file_rows]
        end)

      [{:diff_all, total_adds, total_dels} | dir_rows]
    end
  end

  @doc "Renders the sidebar `%WidgetList{}` widget for the diff tab."
  def render_diff(entries, cursor, focus) do
    %WidgetList{
      items: Enum.map(entries, &item/1),
      selected: cursor,
      block: %Block{
        title: " Changed Files ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(focus, :sidebar)
      },
      highlight_style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]},
      highlight_symbol: "▶ "
    }
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
        %Span{content: "  ▸ ", style: %Style{fg: :dark_gray}},
        %Span{content: compact_path(path), style: %Style{fg: :dark_gray}}
      ]
    }
  end

  defp item({:dir, _initiative_id, path, count}) do
    %Line{
      spans: [
        %Span{content: "  ▸ ", style: %Style{fg: :cyan}},
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

  # ── Diff mode items ───────────────────────────────────────────────────────────

  defp item({:diff_all, 0, 0}) do
    %Line{
      spans: [
        %Span{content: "* ", style: %Style{fg: :dark_gray}},
        %Span{content: "all files", style: %Style{fg: :dark_gray}},
        %Span{content: " (no changes)", style: %Style{fg: :dark_gray}}
      ]
    }
  end

  defp item({:diff_all, adds, dels}) do
    %Line{
      spans: [
        %Span{content: "* ", style: %Style{fg: :white}},
        %Span{content: "all files", style: %Style{modifiers: [:bold]}},
        %Span{content: " +#{adds}", style: %Style{fg: :green}},
        %Span{content: " -#{dels}", style: %Style{fg: :red}}
      ]
    }
  end

  defp item({:diff_dir, dir, adds, dels}) do
    %Line{
      spans: [
        %Span{content: "  ▸ ", style: %Style{fg: :cyan}},
        %Span{content: compact_path(dir), style: %Style{fg: :white}},
        %Span{content: " +#{adds}", style: %Style{fg: :green}},
        %Span{content: " -#{dels}", style: %Style{fg: :red}}
      ]
    }
  end

  defp item({:diff_file, _dir, path, adds, dels}) do
    %Line{
      spans: [
        %Span{content: "    ○ ", style: %Style{fg: :dark_gray}},
        %Span{content: Path.basename(path), style: %Style{fg: :white}},
        %Span{content: " +#{adds}", style: %Style{fg: :green}},
        %Span{content: " -#{dels}", style: %Style{fg: :red}}
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

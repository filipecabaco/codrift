defmodule Codrift.TUI.Sidebar do
  @moduledoc """
  Sidebar entry building and rendering for the Codrift TUI.

  ## Context mode entry hierarchy

      {:initiative, id, name, dir_count, agent_count, status}
        {:context_dir, initiative_id, path, agent_count}
          {:context_file, initiative_id, full_path, filename}
          {:agent, id, adapter, status}
        {:dir, initiative_id, path, wt_status | nil, agent_count}
          {:agent, id, adapter, status}

  `wt_status` is `%{branch: String.t(), dirty?: boolean()}` when a worktree is
  active for that dir, or `nil` when no worktree is configured.

  ## Diff mode entry hierarchy

      {:diff_all, total_adds, total_dels}
        {:diff_dir, dir, adds, dels}
          {:diff_file, dir, path, adds, dels}
  """

  alias Codrift.Initiative.{DirEntry, Store}
  alias Codrift.{Paths, Worktree}
  alias Codrift.TUI.Styles

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.List, as: WidgetList

  @type entry ::
          {:initiative, id :: String.t(), name :: String.t(), dir_count :: non_neg_integer(),
           agent_count :: non_neg_integer(), status :: atom()}
          | {:context_dir, initiative_id :: String.t(), path :: String.t(),
             agent_count :: non_neg_integer()}
          | {:context_file, initiative_id :: String.t(), full_path :: String.t(),
             filename :: String.t()}
          | {:dir, initiative_id :: String.t(), path :: String.t(),
             wt_status :: %{branch: String.t(), dirty?: boolean()} | nil,
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

      ctx_path = Store.context_path(initiative.id)
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
          |> Enum.reject(fn f ->
            String.starts_with?(f, ".") or f == "CLAUDE.md" or
              File.dir?(Path.join(path, f))
          end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    header = {:context_dir, initiative_id, path, length(dir_agents)}
    file_rows = Enum.map(files, fn f -> {:context_file, initiative_id, Path.join(path, f), f} end)
    agent_rows = Enum.map(dir_agents, fn a -> {:agent, a.id, a.adapter, a.status} end)
    [header | file_rows ++ agent_rows]
  end

  defp dir_entries(initiative_id, %DirEntry{} = entry, by_dir) do
    effective = DirEntry.effective_path(entry)
    dir_agents = Map.get(by_dir, effective, [])

    wt_status =
      if entry.worktree_enabled and is_binary(entry.worktree_path) and
           File.dir?(entry.worktree_path) do
        Worktree.status(entry.worktree_path)
      end

    header = {:dir, initiative_id, entry.path, wt_status, length(dir_agents)}
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
      dir_rows = Enum.flat_map(nonempty, &build_dir_row/1)
      [{:diff_all, total_adds, total_dels} | dir_rows]
    end
  end

  defp build_dir_row({dir, files}) do
    dir_adds = Enum.sum(Enum.map(files, & &1.additions))
    dir_dels = Enum.sum(Enum.map(files, & &1.deletions))
    file_rows = Enum.map(files, fn f -> {:diff_file, dir, f.path, f.additions, f.deletions} end)
    [{:diff_dir, dir, dir_adds, dir_dels} | file_rows]
  end

  @doc "Renders the sidebar `%WidgetList{}` widget for the diff tab."
  def render_diff(entries, cursor, focus, theme \\ nil) do
    %WidgetList{
      items: Enum.map(entries, &item/1),
      selected: cursor,
      block: %Block{
        title: " Changed Files ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(focus, :sidebar, theme)
      },
      highlight_style: Styles.sidebar_highlight(theme),
      highlight_symbol: "▶ "
    }
  end

  @doc "Renders the sidebar `%WidgetList{}` widget."
  def render(entries, cursor, focus, theme \\ nil) do
    %WidgetList{
      items: Enum.map(entries, &item/1),
      selected: cursor,
      block: %Block{
        title: " Initiatives ",
        borders: [:all],
        border_type: :rounded,
        border_style: Styles.pane_border(focus, :sidebar, theme)
      },
      highlight_style: Styles.sidebar_highlight(theme),
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

  defp item({:dir, _initiative_id, path, wt_status, 0}) do
    spans =
      [
        %Span{content: "  ▸ ", style: %Style{fg: :dark_gray}},
        %Span{content: Path.basename(path), style: %Style{fg: :dark_gray}}
      ] ++ wt_spans(wt_status)

    %Line{spans: spans}
  end

  defp item({:dir, _initiative_id, path, wt_status, count}) do
    spans =
      [
        %Span{content: "  ▸ ", style: %Style{fg: :cyan}},
        %Span{content: Path.basename(path), style: %Style{fg: :white}}
      ] ++
        wt_spans(wt_status) ++
        [%Span{content: " [#{count}]", style: %Style{fg: :dark_gray}}]

    %Line{spans: spans}
  end

  defp item({:agent, _id, adapter, status}) do
    color = Styles.status_color(status)

    %Line{
      spans: [
        %Span{content: "    ◦ ", style: %Style{fg: color}},
        %Span{content: Codrift.Agent.adapter_name(adapter), style: %Style{fg: :white}},
        %Span{content: " (#{Styles.format_status(status)})", style: %Style{fg: color}}
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
        %Span{content: Paths.compact(dir), style: %Style{fg: :white}},
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

  defp wt_spans(nil), do: []
  defp wt_spans(%{dirty?: true}), do: [%Span{content: " [wt*]", style: %Style{fg: :yellow}}]
  defp wt_spans(%{dirty?: false}), do: [%Span{content: " [wt]", style: %Style{fg: :dark_gray}}]

  defp status_display(:planning), do: {"◷", :blue}
  defp status_display(:ongoing), do: {"●", :green}
  defp status_display(:done), do: {"✓", :cyan}
  defp status_display(:archived), do: {"○", :dark_gray}
  defp status_display(_), do: {"○", :dark_gray}
end

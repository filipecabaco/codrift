defmodule Codrift.CLI.Initiative do
  @moduledoc """
  CLI implementation for initiative management commands.

  Reads and writes `~/.config/codrift/initiatives.json` directly — no
  GenServer required — so it works both in the release `eval` context and
  when the TUI is not running.

  All output is JSON to stdout; errors go to stderr with a non-zero exit.

  ## Usage

      codrift initiative list
      codrift initiative show   <id>
      codrift initiative create <name>
      codrift initiative add-dir <id> <path>
      codrift initiative status  <id> <status>
      codrift initiative delete  <id>
  """

  alias Codrift.{ClaudePermissions, Initiative}
  alias Codrift.Initiative.{DirEntry, Store}
  alias Codrift.Worktree

  @default_path "~/.config/codrift/initiatives.json"

  # ── Dispatch ─────────────────────────────────────────────────────────────────

  @doc "Dispatches initiative CLI subcommands from argv."
  @spec run([String.t()]) :: :ok
  def run(["list" | _]) do
    initiatives = load_sorted()
    print_json(%{initiatives: Enum.map(initiatives, &Initiative.to_map/1)})
  end

  def run(["show", id | _]) do
    case find_by_id(id) do
      nil -> fail("initiative not found: #{id}")
      initiative -> print_json(Initiative.to_map(initiative))
    end
  end

  def run(["create", name | _]) do
    initiatives = load_map()
    initiative = Initiative.new(name)

    # Create context folder, init git repo, and write initiative.md.
    # write_initiative_md_for_cli handles git-init + symlink internally so the
    # context folder is identical to one created by the GenServer path.
    ctx = context_path(initiative.id)
    File.mkdir_p!(ctx)

    Store.write_initiative_md_for_cli(ctx, initiative)

    new_map = Map.put(initiatives, initiative.id, initiative)
    persist(new_map)

    print_json(Initiative.to_map(initiative))
  end

  def run(["add-dir", id, dir | _]) do
    expanded = Path.expand(dir)

    update_initiative(id, fn i ->
      if Enum.any?(i.dirs, &(&1.path == expanded)) do
        i
      else
        ClaudePermissions.add(expanded, "Read")
        %{i | dirs: [DirEntry.new(expanded) | i.dirs]}
      end
    end)
  end

  def run(["status", id, status_str | _]) do
    valid = ~w(planning ongoing done archived)

    if status_str in valid do
      status = String.to_existing_atom(status_str)
      update_initiative(id, fn i -> %{i | status: status} end)
    else
      fail("invalid status '#{status_str}'. Must be one of: #{Enum.join(valid, ", ")}")
    end
  end

  def run(["delete", id | _]) do
    initiatives = load_map()

    case Map.pop(initiatives, id) do
      {nil, _} ->
        fail("initiative not found: #{id}")

      {_, rest} ->
        persist(rest)
        ctx = context_path(id)
        safe_rm_context_dir!(ctx)
        print_json(%{deleted: id})
    end
  end

  def run(["worktree-enable", id, dir | _]) do
    expanded = Path.expand(dir)
    ctx = context_path(id)

    update_initiative(id, fn i ->
      case Enum.find(i.dirs, &(&1.path == expanded)) do
        nil ->
          fail("directory not in initiative: #{expanded}")

        %DirEntry{worktree_path: wt} when is_binary(wt) ->
          fail("worktree already enabled for #{expanded} at #{wt}")

        entry ->
          case Worktree.ensure(ctx, id, expanded) do
            {:ok, wt_path} ->
              updated_entry = %{entry | worktree_enabled: true, worktree_path: wt_path}

              dirs =
                Enum.map(i.dirs, fn e -> if e.path == expanded, do: updated_entry, else: e end)

              %{i | dirs: dirs}

            {:error, reason} ->
              fail("worktree creation failed: #{reason}")
          end
      end
    end)
  end

  def run(["worktree-disable", id, dir | _]) do
    expanded = Path.expand(dir)

    update_initiative(id, fn i ->
      case Enum.find(i.dirs, &(&1.path == expanded)) do
        nil ->
          fail("directory not in initiative: #{expanded}")

        %DirEntry{worktree_path: nil} ->
          fail("no worktree is enabled for #{expanded}")

        entry ->
          Worktree.remove(expanded, entry.worktree_path)
          cleared = %{entry | worktree_enabled: false, worktree_path: nil}
          dirs = Enum.map(i.dirs, fn e -> if e.path == expanded, do: cleared, else: e end)
          %{i | dirs: dirs}
      end
    end)
  end

  def run(["allow-read", id | _]) do
    case find_by_id(id) do
      nil ->
        fail("initiative not found: #{id}")

      initiative ->
        results =
          Enum.map(initiative.dirs, fn entry ->
            effective = DirEntry.effective_path(entry)
            allow = ClaudePermissions.add(effective, "Read")
            %{dir: entry.path, effective: effective, read_allowed: allow}
          end)

        print_json(%{initiative_id: id, dirs: results})
    end
  end

  def run(["revoke-read", id | _]) do
    case find_by_id(id) do
      nil ->
        fail("initiative not found: #{id}")

      initiative ->
        results =
          Enum.map(initiative.dirs, fn entry ->
            effective = DirEntry.effective_path(entry)
            allow = ClaudePermissions.remove(effective, "Read")
            %{dir: entry.path, effective: effective, read_allowed: allow}
          end)

        print_json(%{initiative_id: id, dirs: results})
    end
  end

  def run(["worktree-status", id | _]) do
    case find_by_id(id) do
      nil ->
        fail("initiative not found: #{id}")

      initiative ->
        statuses =
          Enum.map(initiative.dirs, fn entry ->
            wt_info =
              if entry.worktree_enabled and is_binary(entry.worktree_path) and
                   File.dir?(entry.worktree_path) do
                st = Worktree.status(entry.worktree_path)
                %{enabled: true, path: entry.worktree_path, branch: st.branch, dirty: st.dirty?}
              else
                %{enabled: false, path: nil, branch: nil, dirty: false}
              end

            %{dir: entry.path, worktree: wt_info}
          end)

        print_json(%{initiative_id: id, dirs: statuses})
    end
  end

  def run(_) do
    IO.puts("""
    Usage:
      codrift initiative list
      codrift initiative show   <id>
      codrift initiative create <name>
      codrift initiative add-dir <id> <path>
      codrift initiative status  <id> planning|ongoing|done|archived
      codrift initiative delete  <id>
      codrift initiative allow-read   <id>    # write Read to .claude/settings.json in all dirs
      codrift initiative revoke-read  <id>    # remove Read from .claude/settings.json in all dirs
      codrift initiative worktree-enable  <id> <dir>
      codrift initiative worktree-disable <id> <dir>
      codrift initiative worktree-status  <id>
    """)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp update_initiative(id, fun) do
    initiatives = load_map()

    case Map.fetch(initiatives, id) do
      {:ok, initiative} ->
        updated = fun.(initiative)
        persist(Map.put(initiatives, id, updated))
        print_json(Initiative.to_map(updated))

      :error ->
        fail("initiative not found: #{id}")
    end
  end

  defp load_map do
    path = Path.expand(@default_path)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, %{"initiatives" => raw}} <- JSON.decode(content) do
      raw
      |> Enum.flat_map(&parse_initiative_entry/1)
      |> Map.new()
    else
      _ -> %{}
    end
  end

  defp parse_initiative_entry({id, data}) do
    case Initiative.from_map(data) do
      {:ok, initiative} -> [{id, initiative}]
      _ -> []
    end
  end

  defp load_sorted do
    load_map()
    |> Map.values()
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  defp find_by_id(id) do
    Map.get(load_map(), id)
  end

  defp persist(initiatives_map) do
    path = Path.expand(@default_path)
    path |> Path.dirname() |> File.mkdir_p!()
    data = Map.new(initiatives_map, fn {id, i} -> {id, Initiative.to_map(i)} end)
    File.write!(path, JSON.encode!(%{"initiatives" => data}))
  end

  defp context_path(id), do: Path.expand("~/.codrift/initiatives/#{id}")

  # Mirrors the path-traversal guard in Codrift.Initiative.Store.
  # Only removes paths that are direct children of ~/.codrift/initiatives/
  # to prevent accidental deletion of unrelated directories.
  defp safe_rm_context_dir!(path) do
    base = Path.expand("~/.codrift/initiatives")
    expanded = Path.expand(path)

    unless Path.dirname(expanded) == base do
      raise "Codrift safety: refusing to delete '#{expanded}' — " <>
              "expected a direct child of #{base}"
    end

    if File.dir?(expanded), do: File.rm_rf!(expanded)
  end

  defp print_json(data), do: IO.puts(JSON.encode!(data))

  @spec fail(String.t()) :: no_return()
  defp fail(msg) do
    IO.puts(:stderr, JSON.encode!(%{error: msg}))
    System.halt(1)
  end
end

defmodule Codrift.Initiative.Store do
  @moduledoc """
  GenServer that holds initiatives in memory and persists them to a JSON file.

  The file path defaults to `~/.config/codrift/initiatives.json` and is
  configurable via the `:path` option on `start_link/1` (used in tests to
  write to a temporary directory).

  Pass `name: nil` to start an unnamed instance for test isolation.

  ## Context folders

  Each initiative gets a dedicated context folder at
  `~/.codrift/initiatives/{id}/` where users can place project context files
  (READMEs, ticket exports, documentation) to feed to AI agents. The folder
  is created automatically on `create/2` and removed on `delete/1`.
  """

  use GenServer

  require Logger

  alias Codrift.Initiative

  @default_path "~/.config/codrift/initiatives.json"

  @doc "Returns the context folder path for an initiative (pure function, no GenServer call)."
  def context_path(id), do: Path.expand("~/.codrift/initiatives/#{id}")

  @doc """
  Returns `true` when `path` is strictly inside `~/.codrift/initiatives/`.

  Used as a safety guard before any read, write, or delete operation on
  context files, preventing accidental access to project directories outside
  the managed tree.
  """
  def context_file_path?(nil), do: false

  def context_file_path?(path) do
    base = Path.expand("~/.codrift/initiatives")
    expanded = Path.expand(path)
    String.starts_with?(expanded, base <> "/")
  end

  @doc "Starts the store, optionally accepting `:name` and `:path` opts."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Creates a new initiative, creates its context folder, and persists it."
  def create(name, dirs \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:create, name, dirs})
  end

  @doc "Fetches an initiative by ID. Returns `{:error, :not_found}` if absent."
  def get(id, server \\ __MODULE__) do
    GenServer.call(server, {:get, id})
  end

  @doc "Returns all initiatives sorted by creation time (oldest first)."
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc "Adds a directory to an initiative (idempotent — duplicate dirs are ignored)."
  def add_dir(id, dir, server \\ __MODULE__) do
    GenServer.call(server, {:add_dir, id, dir})
  end

  @doc "Removes a directory from an initiative. No-op if the dir is not present."
  def remove_dir(id, dir, server \\ __MODULE__) do
    GenServer.call(server, {:remove_dir, id, dir})
  end

  @doc "Deletes an initiative and removes its context folder. Returns `{:error, :not_found}` if absent."
  def delete(id, server \\ __MODULE__) do
    GenServer.call(server, {:delete, id})
  end

  @doc "Sets the lifecycle status of an initiative (:planning | :ongoing | :done | :archived)."
  def set_status(id, status, server \\ __MODULE__) do
    GenServer.call(server, {:set_status, id, status})
  end

  @impl true
  def init(opts) do
    path = Path.expand(Keyword.get(opts, :path, @default_path))
    initiatives = load(path)
    # Ensure context dirs, CLAUDE.md symlinks, and git repos exist for all
    # previously-created initiatives (backfills anything created before these
    # features were added, and recreates dirs that were accidentally deleted).
    Enum.each(initiatives, fn {_id, initiative} ->
      ctx = context_path(initiative.id)
      File.mkdir_p!(ctx)
      ensure_git_repo(ctx)
      ensure_claude_md_symlink(ctx)
    end)

    clean_orphaned_context_dirs(initiatives)

    {:ok, %{initiatives: initiatives, path: path}}
  end

  @impl true
  def handle_call({:create, name, dirs}, _from, state) do
    initiative = Initiative.new(name, dirs)
    ctx = context_path(initiative.id)
    File.mkdir_p!(ctx)
    ensure_git_repo(ctx)
    write_initiative_md(ctx, initiative)
    new_state = put_initiative(state, initiative)
    {:reply, {:ok, initiative}, new_state}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state.initiatives, id) do
      {:ok, initiative} -> {:reply, {:ok, initiative}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    sorted =
      state.initiatives
      |> Map.values()
      |> Enum.sort_by(& &1.created_at, DateTime)

    {:reply, sorted, state}
  end

  def handle_call({:add_dir, id, dir}, _from, state) do
    case update_initiative(state, id, fn i -> %{i | dirs: Enum.uniq([dir | i.dirs])} end) do
      {:reply, {:ok, initiative}, new_state} ->
        update_initiative_md_dirs(initiative)
        {:reply, {:ok, initiative}, new_state}

      error_reply ->
        error_reply
    end
  end

  def handle_call({:remove_dir, id, dir}, _from, state) do
    case update_initiative(state, id, fn i -> %{i | dirs: List.delete(i.dirs, dir)} end) do
      {:reply, {:ok, initiative}, new_state} ->
        update_initiative_md_dirs(initiative)
        {:reply, {:ok, initiative}, new_state}

      error_reply ->
        error_reply
    end
  end

  def handle_call({:delete, id}, _from, state) do
    case Map.pop(state.initiatives, id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {_, initiatives} ->
        new_state = %{state | initiatives: initiatives}
        persist(new_state)
        safe_rm_context_dir!(context_path(id))
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:set_status, id, status}, _from, state) do
    update_initiative(state, id, fn i -> %{i | status: status} end)
  end

  defp put_initiative(state, initiative) do
    new_state = %{state | initiatives: Map.put(state.initiatives, initiative.id, initiative)}
    persist(new_state)
    new_state
  end

  defp update_initiative(state, id, fun) do
    case Map.fetch(state.initiatives, id) do
      {:ok, initiative} ->
        updated = fun.(initiative)
        new_state = put_initiative(state, updated)
        {:reply, {:ok, updated}, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # Deletes `path` only when it is a direct child of ~/.codrift/initiatives/.
  # Prevents any possible path-traversal or misconfiguration from touching
  # project directories that live outside our managed tree.
  # Removes context dirs for initiatives that no longer exist in the store.
  # Runs once at startup so stale directories from deleted initiatives are
  # automatically pruned. Uses `safe_rm_context_dir!/1` so it can only touch
  # direct children of `~/.codrift/initiatives/`.
  defp clean_orphaned_context_dirs(initiatives) do
    base = Path.expand("~/.codrift/initiatives")

    case File.ls(base) do
      {:ok, entries} ->
        known_ids = MapSet.new(Map.keys(initiatives))

        entries
        |> Enum.filter(fn name ->
          full = Path.join(base, name)
          File.dir?(full) and not MapSet.member?(known_ids, name)
        end)
        |> Enum.each(fn name ->
          full = Path.join(base, name)
          Logger.info("Codrift.Initiative.Store: removing orphaned context dir #{full}")
          safe_rm_context_dir!(full)
        end)

      {:error, _} ->
        :ok
    end
  end

  defp ensure_git_repo(path) do
    unless File.dir?(Path.join(path, ".git")) do
      System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    end
  end

  defp safe_rm_context_dir!(path) do
    base = Path.expand("~/.codrift/initiatives")
    expanded = Path.expand(path)

    # Must be exactly one level below the base (no traversal, no deleting base itself)
    unless Path.dirname(expanded) == base do
      raise "Codrift safety: refusing to delete '#{expanded}' — " <>
              "expected a direct child of #{base}"
    end

    File.rm_rf!(expanded)
  end

  @doc """
  Writes `initiative.md` and ensures the `CLAUDE.md` symlink.

  Public so that `Codrift.CLI.Initiative` can call it when creating an
  initiative outside the supervision tree.
  """
  def write_initiative_md_for_cli(ctx_path, initiative) do
    # Mirrors handle_call({:create, ...}): ensure_git_repo must be called so
    # that context folders created by the CLI are identical to those created by
    # the GenServer (both have a .git repo for diff tracking).
    ensure_git_repo(ctx_path)
    write_initiative_md(ctx_path, initiative)
  end

  # Creates initiative.md on first run. If the file already exists (pre-seeded
  # context folder) the user-editable sections are untouched; only the managed
  # dirs block is refreshed.
  #
  # Also ensures a CLAUDE.md symlink → initiative.md exists so that Claude Code's
  # `--add-dir` flag picks up the initiative context as project context.
  defp write_initiative_md(ctx_path, initiative) do
    md = Path.join(ctx_path, "initiative.md")

    if File.exists?(md) do
      update_initiative_md_dirs(initiative)
    else
      File.write!(md, initial_initiative_md(initiative))
    end

    ensure_claude_md_symlink(ctx_path)
  end

  # Creates CLAUDE.md as a symlink to initiative.md in `ctx_path` if absent.
  # Uses a relative target so the symlink stays valid if the whole initiatives
  # folder is moved.
  defp ensure_claude_md_symlink(ctx_path) do
    claude_md = Path.join(ctx_path, "CLAUDE.md")

    unless File.exists?(claude_md) or match?({:ok, _}, File.read_link(claude_md)) do
      File.ln_s!("initiative.md", claude_md)
    end
  end

  # Updates only the <!-- codrift:dirs:start/end --> block in an existing file,
  # preserving all user-editable content (Goal, Context, Notes, etc.).
  defp update_initiative_md_dirs(initiative) do
    md = Path.join(context_path(initiative.id), "initiative.md")

    case File.read(md) do
      {:ok, content} ->
        block = dirs_block(initiative.dirs)

        updated =
          if String.contains?(content, "<!-- codrift:dirs:start -->") do
            Regex.replace(
              ~r/<!-- codrift:dirs:start -->.*?<!-- codrift:dirs:end -->/s,
              content,
              block
            )
          else
            content
          end

        File.write!(md, updated)

      {:error, _} ->
        :ok
    end
  end

  defp initial_initiative_md(initiative) do
    types = Enum.join(Codrift.Memory.valid_types(), ", ")

    """
    # #{initiative.name}

    ## Initiative

    ID: #{initiative.id}
    Name: #{initiative.name}

    #{dirs_block(initiative.dirs)}

    ## Memory Store

    Shared knowledge base for all agents on this initiative.
    Search it before starting work; update it when you finish or make a decision.
    This saves tokens and keeps all agents aligned.

    Valid types: #{types}

    ### Via MCP tool (Claude Code — preferred):

    Use the structured tools: `memory_search`, `memory_add`, `memory_delete`,
    `memory_recent`, `memory_list`. Pass `initiative_id: "#{initiative.id}"` to each.

    ### Via CLI (any agent):

        codrift memory search #{initiative.id} "your query"
        codrift memory add    #{initiative.id} decision "we use JWT not sessions"
        codrift memory add    #{initiative.id} summary  "completed auth module"
        codrift memory add    #{initiative.id} snippet  "pattern or code fragment"
        codrift memory delete #{initiative.id} <id>
        codrift memory recent #{initiative.id}
        codrift memory list   #{initiative.id} decision

    Results include an `id` field — use it with `memory delete` to remove outdated entries.

    ## Goal

    <!-- What does this initiative aim to achieve? -->

    ## Context

    <!-- Key background information, relevant links, prior decisions -->

    ## Notes

    <!-- Running notes, open questions, updates -->
    """
  end

  defp dirs_block(dirs) do
    body =
      case dirs do
        [] ->
          "(no project directories configured yet — use 'a' in the TUI to add one)"

        dirs ->
          Enum.map_join(dirs, "\n", fn dir -> "- #{Codrift.Paths.compact(dir)}" end)
      end

    "<!-- codrift:dirs:start -->\n## Directories\n\n#{body}\n<!-- codrift:dirs:end -->"
  end

  defp persist(%{initiatives: initiatives, path: path}) do
    data = Map.new(initiatives, fn {id, i} -> {id, Initiative.to_map(i)} end)
    json = JSON.encode!(%{"initiatives" => data})
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, json)
  end

  defp load(path) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, %{"initiatives" => raw}} <- JSON.decode(content) do
      raw
      |> Enum.flat_map(&parse_raw_initiative/1)
      |> Map.new()
    else
      _ -> %{}
    end
  end

  defp parse_raw_initiative({id, data}) do
    case Initiative.from_map(data) do
      {:ok, initiative} ->
        [{id, initiative}]

      {:error, reason} ->
        Logger.warning("Skipping malformed initiative #{inspect(id)}: #{inspect(reason)}")
        []
    end
  end
end

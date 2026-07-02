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

  alias Codrift.{ClaudePermissions, Initiative}
  alias Codrift.Initiative.DirEntry
  alias Codrift.Worktree

  @doc "Returns the context folder path for an initiative (pure function, no GenServer call)."
  def context_path(id), do: Codrift.Paths.initiative_dir(id)

  @doc """
  Returns `true` when `path` is strictly inside `~/.codrift/initiatives/`.

  Used as a safety guard before any read, write, or delete operation on
  context files, preventing accidental access to project directories outside
  the managed tree.
  """
  def context_file_path?(nil), do: false

  def context_file_path?(path) do
    base = Codrift.Paths.initiatives_base()
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

  @doc """
  Adds a directory to an initiative (idempotent — duplicate paths are ignored).

  Pass `worktree_enabled: true` in `opts` to create a git worktree for the
  directory. If the dir is not a git repo the option is silently ignored.
  Accepts an optional `server` pid/name as the last positional argument.
  """
  def add_dir(id, dir, opts \\ [])
  def add_dir(id, dir, opts) when is_list(opts), do: add_dir(id, dir, opts, __MODULE__)
  def add_dir(id, dir, server), do: add_dir(id, dir, [], server)

  @doc "Same as `add_dir/3` but allows passing both opts and a server."
  def add_dir(id, dir, opts, server), do: GenServer.call(server, {:add_dir, id, dir, opts})

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

  @doc "Links an initiative to an external integration item and sets the initial status."
  def link_integration(id, service, item_id, server \\ __MODULE__) do
    GenServer.call(server, {:link_integration, id, service, item_id})
  end

  @doc "Sets the initiative-level default for whether new dirs should use git worktrees."
  def set_worktree_default(id, default, server \\ __MODULE__) do
    GenServer.call(server, {:set_worktree_default, id, default})
  end

  @doc """
  Toggles git worktree on or off for an existing directory.

  Enabling creates the worktree. Disabling removes it and clears the path.
  Returns `{:error, :not_found}` when the initiative or dir is absent.
  """
  def toggle_dir_worktree(id, dir, server \\ __MODULE__) do
    GenServer.call(server, {:toggle_dir_worktree, id, dir})
  end

  @impl true
  def init(opts) do
    default_path = Path.join(Codrift.Paths.config_dir(), "initiatives.json")
    path = Path.expand(Keyword.get(opts, :path, default_path))
    ctx_base = Path.expand(Keyword.get(opts, :context_dir_base, Codrift.Paths.initiatives_base()))
    initiatives = load(path)
    # Ensure context dirs, CLAUDE.md symlinks, and git repos exist for all
    # previously-created initiatives (backfills anything created before these
    # features were added, and recreates dirs that were accidentally deleted).
    Enum.each(initiatives, fn {_id, initiative} ->
      ctx = ctx_path(ctx_base, initiative.id)
      File.mkdir_p!(ctx)
      ensure_git_repo(ctx)
      ensure_claude_md_symlink(ctx)
      write_orchestration_md(ctx, initiative)
    end)

    clean_orphaned_context_dirs(initiatives, ctx_base)

    {:ok, %{initiatives: initiatives, path: path, context_dir_base: ctx_base}}
  end

  @impl true
  def handle_call({:create, name, dirs}, _from, state) do
    initiative = Initiative.new(name, dirs)
    new_state = put_initiative(state, initiative)
    {:reply, {:ok, initiative}, new_state, {:continue, {:setup_context, initiative}}}
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

  def handle_call({:add_dir, id, dir, opts}, _from, state) do
    worktree_enabled = Keyword.get(opts, :worktree_enabled, false)
    ctx = ctx_path(state.context_dir_base, id)

    case update_initiative(state, id, &maybe_add_dir(&1, ctx, id, dir, worktree_enabled)) do
      {:reply, {:ok, initiative}, new_state} ->
        {:reply, {:ok, initiative}, new_state,
         {:continue, {:add_dir_side_effects, initiative, dir}}}

      error_reply ->
        error_reply
    end
  end

  def handle_call({:remove_dir, id, dir}, _from, state) do
    case Map.fetch(state.initiatives, id) do
      {:ok, initiative} ->
        {to_remove, remaining} = Enum.split_with(initiative.dirs, &(&1.path == dir))
        # Worktree removal is synchronous: callers expect the directory to be
        # gone before the reply (e.g. the TUI refreshes immediately after).
        Enum.each(to_remove, &cleanup_worktree/1)
        updated = %{initiative | dirs: remaining}
        new_state = put_initiative(state, updated)
        {:reply, {:ok, updated}, new_state, {:continue, {:update_initiative_md, updated}}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    case Map.pop(state.initiatives, id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {initiative, initiatives} ->
        new_state = %{state | initiatives: initiatives}
        persist(new_state)
        # Worktree and context-dir cleanup are synchronous: callers (TUI, tests)
        # expect the directory to be absent before the reply returns.
        Enum.each(initiative.dirs, &cleanup_worktree/1)
        safe_rm_context_dir!(ctx_path(state.context_dir_base, id), state.context_dir_base)
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:set_status, id, status}, _from, state) do
    update_initiative(state, id, fn i -> %{i | status: status} end)
  end

  def handle_call({:link_integration, id, service, item_id}, _from, state) do
    update_initiative(state, id, fn i ->
      %{i | integration: %{service: service, item_id: item_id}}
    end)
  end

  def handle_call({:set_worktree_default, id, default}, _from, state) do
    update_initiative(state, id, fn i -> %{i | worktree_default: default} end)
  end

  def handle_call({:toggle_dir_worktree, id, dir}, _from, state) do
    case Map.fetch(state.initiatives, id) do
      {:ok, initiative} -> do_toggle_dir_worktree(state, initiative, id, dir)
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  defp do_toggle_dir_worktree(state, initiative, id, dir) do
    case Enum.find(initiative.dirs, &(&1.path == dir)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated = apply_worktree_toggle(initiative, entry, id, dir, state)
        new_state = put_initiative(state, updated)
        {:reply, {:ok, updated}, new_state, {:continue, {:update_initiative_md, updated}}}
    end
  end

  defp apply_worktree_toggle(initiative, %DirEntry{worktree_path: nil} = entry, id, dir, state) do
    ctx = ctx_path(state.context_dir_base, id)
    updated_entry = enable_worktree_entry(entry, ctx, id, dir)
    update_initiative_dirs(initiative, dir, updated_entry)
  end

  defp apply_worktree_toggle(initiative, entry, _id, dir, _state) do
    cleanup_worktree(entry)
    cleared = %{entry | worktree_enabled: false, worktree_path: nil}
    update_initiative_dirs(initiative, dir, cleared)
  end

  defp enable_worktree_entry(entry, ctx, id, dir) do
    case Worktree.ensure(ctx, id, dir) do
      {:ok, wt_path} ->
        ClaudePermissions.add(wt_path, "Read")
        %{entry | worktree_enabled: true, worktree_path: wt_path}

      {:error, reason} ->
        Logger.warning("Codrift.Worktree: enable failed for #{dir}: #{inspect(reason)}")
        entry
    end
  end

  defp update_initiative_dirs(initiative, dir, updated_entry) do
    dirs = Enum.map(initiative.dirs, &if(&1.path == dir, do: updated_entry, else: &1))
    %{initiative | dirs: dirs}
  end

  defp maybe_add_dir(initiative, ctx, id, dir, worktree_enabled) do
    if Enum.any?(initiative.dirs, &(&1.path == dir)) do
      initiative
    else
      entry = build_dir_entry(ctx, id, dir, worktree_enabled)
      %{initiative | dirs: [entry | initiative.dirs]}
    end
  end

  @impl true
  def handle_continue({:setup_context, initiative}, state) do
    ctx = ctx_path(state.context_dir_base, initiative.id)
    File.mkdir_p!(ctx)
    ensure_git_repo(ctx)
    write_initiative_md(ctx, initiative)
    write_orchestration_md(ctx, initiative)
    {:noreply, state}
  end

  def handle_continue({:add_dir_side_effects, initiative, dir}, state) do
    update_initiative_md_dirs(initiative, state.context_dir_base)

    case Enum.find(initiative.dirs, &(&1.path == dir)) do
      nil -> :ok
      entry -> ClaudePermissions.add(DirEntry.effective_path(entry), "Read")
    end

    {:noreply, state}
  end

  def handle_continue({:update_initiative_md, initiative}, state) do
    update_initiative_md_dirs(initiative, state.context_dir_base)
    {:noreply, state}
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
  defp clean_orphaned_context_dirs(initiatives, base) do
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
          safe_rm_context_dir!(full, base)
        end)

      {:error, _} ->
        :ok
    end
  end

  defp ctx_path(base, id), do: Path.join(base, id)

  defp ensure_git_repo(path) do
    unless File.dir?(Path.join(path, ".git")) do
      System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    end
  end

  defp safe_rm_context_dir!(path, base) do
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
    write_orchestration_md(ctx_path, initiative)
  end

  @doc """
  Returns the path to `orchestration.md` for an initiative.

  Pure function — no GenServer call.
  """
  def orchestration_md_path(id),
    do: Path.join(Codrift.Paths.initiative_dir(id), "orchestration.md")

  @doc """
  Reads `orchestration.md` for an initiative.

  Returns `{:ok, content}` when the file exists, or `{:error, reason}` otherwise.
  """
  def read_orchestration_md(id) do
    File.read(orchestration_md_path(id))
  end

  @doc """
  Overwrites `orchestration.md` for an initiative with `content`.

  Unlike `write_orchestration_md/2` (private), this always writes — it is
  intended for the MCP `update_orchestration_md` tool and TUI editor flows
  where the user explicitly wants to replace the file.

  Returns `:ok` or `{:error, reason}`.
  """
  def update_orchestration_md(id, content) do
    path = orchestration_md_path(id)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write(path, content)
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

  # Writes orchestration.md only on first creation — never overwrites so users
  # can freely edit it to customise the orchestrator's behaviour.
  defp write_orchestration_md(ctx_path, initiative) do
    path = Path.join(ctx_path, "orchestration.md")
    unless File.exists?(path), do: File.write!(path, default_orchestration_md(initiative))
  end

  defp default_orchestration_md(initiative) do
    """
    # Orchestration: #{initiative.name}

    This file is read by the orchestrator agent at startup. Edit any section to
    shape how work is planned and coordinated. The orchestrator acts on whatever
    is written here, so replace placeholder text with specifics when you have them.

    ## Roles

    **Orchestrator** — you. A single agent running in the initiative context
    directory. You do not edit code directly. Your job is to plan, delegate,
    monitor, and synthesise. You communicate with agents through MCP tools only.

    **Agents** — worker agents started by you via `start_agent`, one per working
    directory. Each agent is isolated: it only sees its own directory and receives
    exactly the prompt you send it via `send_to_agent`. Agents do the actual
    file-editing work. They do not communicate with each other or with you
    directly — you poll their output with `get_agent_output`.

    ## Goal

    Not yet specified. Derive the goal from the task description provided at
    startup and the contents of the working directories.

    ## Workflow

    Follow this loop unless the Goal or Constraints say otherwise:

    1. **Explore** — call `get_diff` on the initiative to understand recent
       changes. Read key files in each directory before writing any agent prompts.
    2. **Plan** — decide what each working directory needs independently. Write
       a short, self-contained prompt for each directory's agent before starting
       any of them.
    3. **Delegate** — call `start_agent` for each directory, then `send_to_agent`
       with the prepared prompt. Start agents in parallel where the work is
       independent; sequence them when one directory's output affects another.
    4. **Monitor** — poll `get_initiative_agents` to check agent status. Use
       `get_agent_output` to read progress and detect blockers. An agent with
       status `idle` or `awaiting_input` is ready for its next instruction.
    5. **Coordinate** — call `memory_search` before making any cross-directory
       architectural decision. Record decisions with `memory_add`
       (chunk_type: `decision`) so agents do not duplicate or contradict work.
    6. **Synthesise** — once all agents are idle or stopped, reconcile their
       output and write a `summary` via `memory_add` covering what changed,
       what was decided, and anything left outstanding.

    ## Constraints

    None specified. Apply sensible defaults:
    - Do not run destructive or irreversible commands without explicit instruction.
    - Prefer small, reviewable changes over large rewrites.
    - If a directory has existing tests, verify they still pass before marking
      that agent's work complete.

    ## Success Criteria

    The task is complete when:
    - All agents are idle or stopped with no unresolved errors.
    - A `summary` memory entry has been written for the initiative.

    Replace these with measurable outcomes specific to the task (e.g. "all tests
    pass in every directory", "a PR is open per repo", "report written to
    output.md").
    """
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
  defp update_initiative_md_dirs(initiative, base \\ Codrift.Paths.initiatives_base()) do
    md = Path.join(ctx_path(base, initiative.id), "initiative.md")

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

  defp build_dir_entry(ctx, initiative_id, dir, true) do
    case Worktree.ensure(ctx, initiative_id, dir) do
      {:ok, wt_path} ->
        DirEntry.new(dir, worktree_enabled: true, worktree_path: wt_path)

      {:error, reason} ->
        Logger.warning(
          "Codrift.Worktree: failed to create worktree for #{dir}: #{inspect(reason)}"
        )

        DirEntry.new(dir)
    end
  end

  defp build_dir_entry(_ctx, _initiative_id, dir, false), do: DirEntry.new(dir)

  defp cleanup_worktree(%DirEntry{worktree_path: nil}), do: :ok
  defp cleanup_worktree(%DirEntry{path: src, worktree_path: wt}), do: Worktree.remove(src, wt)

  defp dirs_block([]) do
    "<!-- codrift:dirs:start -->\n## Directories\n\n(no project directories configured yet — use 'a' in the TUI to add one)\n<!-- codrift:dirs:end -->"
  end

  defp dirs_block(dirs) do
    body = Enum.map_join(dirs, "\n", fn entry -> "- #{Codrift.Paths.compact(entry.path)}" end)
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
      false ->
        %{}

      {:error, reason} ->
        Logger.error("Codrift.Initiative.Store: failed to load #{path}: #{inspect(reason)}")
        %{}

      {:ok, _} ->
        Logger.error(
          "Codrift.Initiative.Store: #{path} has unexpected structure — starting empty"
        )

        %{}
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

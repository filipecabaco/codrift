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

  alias Codrift.Initiative

  @default_path "~/.config/codrift/initiatives.json"

  @doc "Returns the context folder path for an initiative (pure function, no GenServer call)."
  def context_path(id), do: Path.expand("~/.codrift/initiatives/#{id}")

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
    # Ensure CLAUDE.md symlinks exist for all previously-created initiatives
    # (backfills anything created before this feature was added).
    Enum.each(initiatives, fn {_id, initiative} ->
      ctx = context_path(initiative.id)
      if File.dir?(ctx), do: ensure_claude_md_symlink(ctx)
    end)

    {:ok, %{initiatives: initiatives, path: path}}
  end

  @impl true
  def handle_call({:create, name, dirs}, _from, state) do
    initiative = Initiative.new(name, dirs)
    ctx = context_path(initiative.id)
    File.mkdir_p!(ctx)
    write_initiative_md(ctx, initiative)

    case put_initiative(state, initiative) do
      {:ok, new_state} -> {:reply, {:ok, initiative}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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
    result = update_initiative(state, id, fn i -> %{i | dirs: Enum.uniq([dir | i.dirs])} end)
    with {:reply, {:ok, initiative}, _} <- result, do: update_initiative_md_dirs(initiative)
    result
  end

  def handle_call({:remove_dir, id, dir}, _from, state) do
    result = update_initiative(state, id, fn i -> %{i | dirs: List.delete(i.dirs, dir)} end)
    with {:reply, {:ok, initiative}, _} <- result, do: update_initiative_md_dirs(initiative)
    result
  end

  def handle_call({:delete, id}, _from, state) do
    case Map.pop(state.initiatives, id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {_, initiatives} ->
        new_state = %{state | initiatives: initiatives}

        case persist(new_state) do
          :ok ->
            # Best-effort context dir removal — log but don't crash the GenServer.
            try do
              safe_rm_context_dir!(context_path(id))
            rescue
              e -> Logger.warning("Failed to remove context dir for #{id}: #{Exception.message(e)}")
            end

            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:set_status, id, status}, _from, state) do
    update_initiative(state, id, fn i -> %{i | status: status} end)
  end

  # Returns {:ok, new_state} or {:error, reason} — never raises.
  defp put_initiative(state, initiative) do
    new_state = %{state | initiatives: Map.put(state.initiatives, initiative.id, initiative)}

    case persist(new_state) do
      :ok -> {:ok, new_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_initiative(state, id, fun) do
    case Map.fetch(state.initiatives, id) do
      {:ok, initiative} ->
        updated = fun.(initiative)

        case put_initiative(state, updated) do
          {:ok, new_state} -> {:reply, {:ok, updated}, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # Deletes `path` only when it is a direct child of ~/.codrift/initiatives/.
  # Prevents any possible path-traversal or misconfiguration from touching
  # project directories that live outside our managed tree.
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

  # Creates (or repairs) CLAUDE.md as a symlink → initiative.md in `ctx_path`.
  # Uses a relative target so the symlink stays valid if the folder is moved.
  #
  # Three cases handled:
  #   1. CLAUDE.md is a working regular file or symlink → leave it alone.
  #   2. CLAUDE.md is a broken symlink (File.exists? = false, File.lstat succeeds)
  #      → remove the dangling link and recreate it.
  #   3. CLAUDE.md does not exist at all → create the symlink.
  defp ensure_claude_md_symlink(ctx_path) do
    claude_md = Path.join(ctx_path, "CLAUDE.md")

    cond do
      # Working file/symlink — nothing to do.
      File.exists?(claude_md) ->
        :ok

      # Dangling symlink or any other inode that stat can see (lstat succeeds
      # even when the target is missing).  Remove and recreate.
      match?({:ok, _}, File.lstat(claude_md)) ->
        File.rm!(claude_md)
        File.ln_s!("initiative.md", claude_md)

      # Truly absent — create fresh.
      true ->
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
    """
    # #{initiative.name}

    #{dirs_block(initiative.dirs)}

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
          Enum.map_join(dirs, "\n", fn dir -> "- #{shorten_home(dir)}" end)
      end

    "<!-- codrift:dirs:start -->\n## Directories\n\n#{body}\n<!-- codrift:dirs:end -->"
  end

  defp shorten_home(path) do
    home = Path.expand("~")

    if String.starts_with?(path, home),
      do: "~" <> String.slice(path, String.length(home)..-1//1),
      else: path
  end

  # Returns :ok or {:error, reason} — never raises — so callers inside
  # handle_call can return a proper error reply instead of crashing the GenServer.
  # JSON.encode!/1 is safe here because we own the data structure; the only
  # realistic failure modes are the filesystem operations below.
  defp persist(%{initiatives: initiatives, path: path}) do
    data = Map.new(initiatives, fn {id, i} -> {id, Initiative.to_map(i)} end)
    json = JSON.encode!(%{"initiatives" => data})

    with :ok <- path |> Path.dirname() |> File.mkdir_p(),
         :ok <- File.write(path, json) do
      :ok
    end
  end

  defp load(path) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, %{"initiatives" => raw}} <- JSON.decode(content) do
      Map.new(raw, fn {id, data} -> {id, Initiative.from_map(data)} end)
    else
      _ -> %{}
    end
  end
end

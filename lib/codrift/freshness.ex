defmodule Codrift.Freshness do
  @moduledoc """
  Watches the state files this VM is not the only writer of, and turns a change
  on disk into the lifecycle events an open window already knows how to apply.

  Every in-VM mutation broadcasts on its own: `Codrift.Initiative.Store` on each
  write, `Codrift.Memory` on add and delete. That covers the app itself, a second
  window, and an MCP-connected agent — everything sharing this VM.

  It does not cover the CLI. `codrift initiative create` and `codrift memory add`
  run through `bin/codrift eval` in a *separate OS process* and write
  `initiatives.json` and `memory.db` directly, never touching this one. That is
  deliberate and worth preserving — both paths are pure so they work with no
  booted system — so the fix cannot be to route them back through here. Watching
  the files instead costs a `File.stat` per initiative per tick, needs no change
  to the writers, and picks up every external writer there will ever be,
  including a hand edit.

  Two files, two responses:

    * `initiatives.json` — ask the store to `reload/1`. It diffs the file against
      its own state and broadcasts one event per actual difference, so this is
      also what stops the running app from serving a list that no longer matches
      disk.
    * each initiative's `memory.db` — broadcast `{:memory_changed, id}`.

  Latency is one interval, and only for external writes; in-VM writes stay
  instant. Set `config :codrift, freshness_interval: false` to disable polling
  (the default under `mix test`).
  """

  use GenServer

  alias Codrift.Initiative.Store
  alias Codrift.Web.EventRelay

  @default_interval 1_000

  @doc """
  Starts the watcher.

  Accepts `:interval` in milliseconds (`false` disables polling entirely),
  `:store` to point at a non-default `Codrift.Initiative.Store`, and `:name`
  (pass `nil` for an unnamed instance in tests).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Runs one poll now and returns once its events have been broadcast.

  Exists so tests don't have to sleep out an interval.
  """
  def poll(server \\ __MODULE__) do
    GenServer.call(server, :poll)
  end

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, configured_interval()),
      store: Keyword.get(opts, :store, Store),
      # Asked of the store on the first continue rather than derived from
      # Codrift.Paths, so a store pointed at another file is watched correctly.
      paths: nil,
      initiatives: nil,
      memory: %{}
    }

    {:ok, state, {:continue, :seed}}
  end

  @impl true
  def handle_continue(:seed, state) do
    # Seeding only records what is on disk now. Comparing at boot would announce
    # every file as new to a window that has just finished loading them.
    paths = Store.paths(state.store)

    {:noreply,
     schedule(%{
       state
       | paths: paths,
         initiatives: stamp(paths.file),
         memory: memory_stamps(paths, state.store)
     })}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    {:reply, :ok, tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, state |> tick() |> schedule()}
  end

  # An unexpected message must not take the watcher down and with it the only
  # notice an open window gets of CLI writes.
  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(%{interval: interval} = state) when is_integer(interval) do
    Process.send_after(self(), :tick, interval)
    state
  end

  defp schedule(state), do: state

  defp tick(state) do
    stamps = memory_stamps(state.paths, state.store)

    for {id, stamp} <- stamps, not is_nil(stamp), stamp != Map.get(state.memory, id) do
      EventRelay.broadcast({:memory_changed, id})
    end

    %{state | memory: stamps, initiatives: reload_if_changed(state)}
  end

  # The store's own writes move this file too, so a tick right after an in-VM
  # mutation reloads redundantly. Harmless: the reload diffs against state that
  # already matches disk and broadcasts nothing.
  #
  # `reload/1` does the announcing — it holds the previous state, so only it can
  # say which initiatives actually differ. Re-stamped *after* the reload, since
  # the store persists as part of reloading and stamping the older mtime would
  # make the next tick reload again, forever.
  defp reload_if_changed(state) do
    case stamp(state.paths.file) do
      same when same == state.initiatives ->
        same

      changed ->
        safely(changed, fn ->
          Store.reload(state.store)
          stamp(state.paths.file)
        end)
    end
  end

  defp memory_stamps(paths, store) do
    Map.new(initiative_ids(store), &{&1, stamp(memory_path(paths, &1))})
  end

  defp initiative_ids(store) do
    safely([], fn -> Enum.map(Store.list(store), & &1.id) end)
  end

  # A store that is not running yet — or at all — is not this process's problem.
  defp safely(fallback, fun) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  defp memory_path(%{context_dir_base: base}, id),
    do: Path.join([base, id, Codrift.Memory.db_file()])

  # Size as well as mtime because mtime has one-second resolution on some
  # filesystems, and two `codrift memory add` calls in the same second are
  # exactly what a working agent does.
  #
  # `-wal` is stamped too: it is where a commit lands under WAL journalling, and
  # a store switched to WAL would otherwise look untouched for a whole checkpoint.
  defp stamp(path) do
    case file_stamp(path) do
      nil -> nil
      main -> {main, file_stamp(path <> "-wal")}
    end
  end

  defp file_stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _} -> nil
    end
  end

  defp configured_interval do
    case Application.get_env(:codrift, :freshness_interval, @default_interval) do
      interval when is_integer(interval) and interval > 0 -> interval
      _ -> false
    end
  end
end

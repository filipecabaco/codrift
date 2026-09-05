defmodule Codrift.Sidecar do
  @moduledoc """
  Recognising — and clearing out — desktop sidecars whose window is gone.

  The Tauri shell is the only thing that ever spawns a packaged sidecar, and
  Burrito's launcher `execve`s the BEAM in place rather than forking, so the
  shell is always the sidecar's direct parent. A packaged sidecar reparented to
  init (PPID 1) has therefore definitively lost its window: nothing will
  heartbeat it again, nothing will SIGTERM it on quit, and it keeps its
  `Codrift.Scheduler` jobs and agent processes running forever.

  That is not hypothetical. A 0.2.8 sidecar was found still holding `:43117`
  three and a half days after its window closed, alongside six more orphans
  going back to 0.1.0 — every launch after the first one died on `:eaddrinuse`
  and told the user to `pkill` by hand.

  Two halves of the answer live here:

    * `reclaim_port/1` takes the port back from an orphan before Bandit tries to
      bind it, so a stale sidecar can no longer lock the user out;
    * `orphan?/0` lets a running sidecar notice that its *own* shell is gone,
      which is the case `Codrift.ShutdownManager`'s heartbeat cannot see (a
      heartbeat that never arrived is indistinguishable from a slow boot).

  Unix only. On other platforms every predicate answers "not an orphan", which
  degrades to the previous behaviour rather than guessing.
  """

  require Logger

  # A packaged sidecar always execs out of Burrito's unpack directory, on both
  # macOS (~/Library/Application Support/.burrito) and Linux (~/.local/share).
  # Requiring `beam.smp` too keeps the release's helper processes
  # (erl_child_setup, inet_gethost) out of the match — they share the path but
  # are not the sidecar.
  @burrito_marker "/.burrito/desktop_"
  @beam "beam.smp"

  # How long a SIGTERMed sidecar gets to release the port. It runs a real
  # application shutdown (agents, worktree locks), so this is not instant.
  @term_grace 5_000
  @kill_grace 2_000
  @poll 200

  @typedoc "Outcome of trying to make the port bindable."
  @type reclaim :: :free | :reclaimed | {:blocked, String.t()}

  @doc """
  Makes `port` bindable, evicting an abandoned sidecar if that is what holds it.

  Returns `:free` when nothing was in the way, `:reclaimed` when an orphan was
  stopped, and `{:blocked, reason}` when the holder is something we must not
  kill — a Codrift that still has a window, or a process we cannot identify.
  """
  @spec reclaim_port(pos_integer()) :: reclaim()
  def reclaim_port(port) do
    if port_bindable?(port),
      do: :free,
      else: reclaim_from(listener_pid(port), port)
  end

  defp reclaim_from(nil, port),
    do: {:blocked, "could not identify the process listening on #{port}"}

  defp reclaim_from(pid, port) do
    if orphan_sidecar?(pid),
      do: evict(pid, port),
      else: {:blocked, "pid #{pid} holds #{port} and is not an abandoned Codrift sidecar"}
  end

  @doc """
  Stops every abandoned packaged sidecar on the machine, returning the pids it
  signalled.

  Freeing the port only deals with the one orphan that happened to win the race
  for it; the rest go on polling integrations and holding agent processes with
  no window to show them in. They can only be cleaned up from outside, so a
  starting sidecar does it on everyone's behalf.
  """
  @spec reap_orphans() :: [pos_integer()]
  def reap_orphans do
    burrito_pids()
    |> Enum.filter(&orphan_sidecar?/1)
    |> Enum.map(fn pid ->
      Logger.warning("[Codrift.Sidecar] stopping abandoned sidecar #{pid} (its window is gone)")
      signal(pid, "TERM")
      pid
    end)
  end

  @doc """
  True when *this* process has lost the shell that spawned it.

  Only meaningful for a packaged sidecar, so the caller has to be one; a plain
  `mix francis.server` is regularly a child of init and perfectly healthy.
  """
  @spec orphan?() :: boolean()
  def orphan? do
    unix?() and parent_pid(self_pid()) == 1
  end

  @doc "True when `pid` is a packaged sidecar that no longer has a parent shell."
  @spec orphan_sidecar?(pos_integer()) :: boolean()
  def orphan_sidecar?(pid) do
    unix?() and pid != self_pid() and parent_pid(pid) == 1 and packaged_sidecar?(command(pid))
  end

  @doc false
  @spec packaged_sidecar?(String.t() | nil) :: boolean()
  def packaged_sidecar?(nil), do: false

  def packaged_sidecar?(command),
    do: String.contains?(command, @burrito_marker) and String.contains?(command, @beam)

  defp evict(pid, port) do
    Logger.warning(
      "[Codrift.Sidecar] port #{port} is held by abandoned sidecar #{pid} — stopping it"
    )

    signal(pid, "TERM")

    if wait_for_port(port, @term_grace) do
      :reclaimed
    else
      Logger.warning("[Codrift.Sidecar] sidecar #{pid} ignored SIGTERM — killing it")
      signal(pid, "KILL")

      if wait_for_port(port, @kill_grace),
        do: :reclaimed,
        else: {:blocked, "sidecar #{pid} was killed but #{port} is still not bindable"}
    end
  end

  defp wait_for_port(_port, remaining) when remaining <= 0, do: false

  defp wait_for_port(port, remaining) do
    Process.sleep(@poll)
    port_bindable?(port) or wait_for_port(port, remaining - @poll)
  end

  # Asks the question Bandit is about to ask, rather than the weaker "does
  # anything answer a connection" — a socket stuck in a half-closed state
  # refuses connections while still owning the address.
  defp port_bindable?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp listener_pid(port) do
    with {out, 0} <- run("lsof", ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN", "-t"]),
         [first | _] <- String.split(out, "\n", trim: true) do
      parse_pid(first)
    else
      _ -> nil
    end
  end

  defp burrito_pids do
    case run("pgrep", ["-f", @burrito_marker]) do
      {out, 0} ->
        out |> String.split("\n", trim: true) |> Enum.map(&parse_pid/1) |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parent_pid(pid) do
    case run("ps", ["-o", "ppid=", "-p", Integer.to_string(pid)]) do
      {out, 0} -> parse_pid(out)
      _ -> nil
    end
  end

  defp command(pid) do
    case run("ps", ["-o", "command=", "-p", Integer.to_string(pid)]) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp signal(pid, name), do: run("kill", ["-#{name}", Integer.to_string(pid)])

  defp parse_pid(text) do
    case text |> String.trim() |> Integer.parse() do
      {pid, _} when pid > 0 -> pid
      _ -> nil
    end
  end

  defp self_pid, do: parse_pid(System.pid())

  defp unix?, do: match?({:unix, _}, :os.type())

  # Every caller here is best-effort: a missing `lsof` on a stripped Linux image
  # must degrade to "cannot tell", never crash the boot that is asking. stderr is
  # folded in rather than inherited so a probe for a pid that has already exited
  # cannot write to the desktop log; a non-zero exit discards the output anyway.
  defp run(command, args) do
    System.cmd(command, args, stderr_to_stdout: true)
  rescue
    _ -> :error
  end
end

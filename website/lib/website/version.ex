defmodule Website.Version do
  @moduledoc """
  The latest published Codrift version, read from the GitHub releases API.

  The homepage used to hard-code the number, which meant it silently went stale
  the moment a release shipped (it read v0.0.1 while v0.0.3 was out).

  Why a TTL cache and not a scheduled job: this runs on a Fly machine with
  `min_machines_running = 0` and `auto_stop_machines = "suspend"`, so there is
  no process alive to fire a timer — the box is asleep between visits. A cache
  checked on request is the only refresh that actually happens. The health check
  in `fly.toml` hits `/` every 30s, so once the machine is awake the TTL is
  re-examined continuously and a fresh release is picked up within the hour.

  The staleness clock is deliberately WALL CLOCK, not monotonic. A Fly suspend
  snapshots RAM and stops the CPU, so on resume `:persistent_term` still holds
  the version cached before the suspend while `System.monotonic_time/1` — which
  is `CLOCK_MONOTONIC` on Linux, and excludes suspended time — has barely
  advanced. A monotonic TTL therefore ages only while the machine happens to be
  awake, which on a site that sleeps between visitors can stretch a nominal day
  into weeks of real time. That is exactly how the homepage came to advertise
  v0.1.0 while v0.2.1 was out. `System.system_time/1` counts the suspend, which
  is the elapsed time we actually mean. NTP nudging it by a few seconds is
  irrelevant against an hour-scale TTL.

  Reads never wait on GitHub twice: the first request with an empty cache blocks
  briefly so the page isn't rendered without a version, and every request after
  that is served from the cache while a stale entry refreshes in the background.
  """

  require Logger

  @key {__MODULE__, :latest}
  @ttl_ms :timer.hours(1)
  @api "https://api.github.com/repos/filipecabaco/codrift/releases/latest"
  # Only the cold-start fetch blocks a render, so keep it short: a slow GitHub
  # should cost the first visitor a version chip, never a timed-out page.
  @cold_timeout_ms 2_000

  @doc """
  Returns the latest version as a string (e.g. `"0.0.3"`), or `nil` when it has
  never been fetched successfully.

  `nil` is deliberate — the template omits the version rather than printing a
  number that might be wrong, which is the failure the hard-coded value had.
  """
  @spec current() :: String.t() | nil
  def current do
    case :persistent_term.get(@key, nil) do
      nil ->
        fetch_and_store() || nil

      {version, fetched_at} ->
        if stale?(fetched_at), do: refresh_async(version, fetched_at)
        version
    end
  end

  # See the moduledoc: wall clock, so that time spent suspended still counts.
  defp now_ms, do: System.system_time(:millisecond)

  defp stale?(fetched_at), do: now_ms() - fetched_at > @ttl_ms

  # Re-stamp the cache before spawning so a burst of concurrent requests queues
  # one refresh between them rather than one each. Losing a race here only costs
  # a duplicate GET, so no lock is warranted.
  defp refresh_async(version, fetched_at) do
    store(version, fetched_at + @ttl_ms)
    Task.start(fn -> fetch_and_store() end)
  end

  defp fetch_and_store do
    case fetch() do
      {:ok, version} ->
        store(version, now_ms())
        version

      {:error, reason} ->
        Logger.warning("could not read the latest codrift release: #{inspect(reason)}")
        nil
    end
  end

  defp store(version, fetched_at), do: :persistent_term.put(@key, {version, fetched_at})

  defp fetch do
    # Unauthenticated, so GitHub allows 60/hour per IP. One refresh an hour plus
    # a fetch per cold start sits far under that, and `refresh_async/2` re-stamps
    # the cache up front so a burst of requests cannot turn into a burst of GETs.
    case Req.get(@api, receive_timeout: @cold_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: %{"tag_name" => "v" <> version}}} -> {:ok, version}
      {:ok, %{status: 200, body: %{"tag_name" => tag}}} -> {:ok, tag}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end

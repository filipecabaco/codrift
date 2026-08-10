defmodule Website.Version do
  @moduledoc """
  The latest published Codrift version, read from the GitHub releases API.

  The homepage used to hard-code the number, which meant it silently went stale
  the moment a release shipped (it read v0.0.1 while v0.0.3 was out).

  Why a TTL cache and not a scheduled job: this runs on a Fly machine with
  `min_machines_running = 0` and `auto_stop_machines = "suspend"`, so there is
  no process alive to fire a daily timer — the box is asleep between visits. A
  cache checked on request is the only refresh that actually happens, and it
  resumes correctly after any suspend.

  Reads never wait on GitHub twice: the first request with an empty cache blocks
  briefly so the page isn't rendered without a version, and every request after
  that is served from the cache while a stale entry refreshes in the background.
  """

  require Logger

  @key {__MODULE__, :latest}
  @ttl_ms :timer.hours(24)
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

  defp stale?(fetched_at), do: System.monotonic_time(:millisecond) - fetched_at > @ttl_ms

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
        store(version, System.monotonic_time(:millisecond))
        version

      {:error, reason} ->
        Logger.warning("could not read the latest codrift release: #{inspect(reason)}")
        nil
    end
  end

  defp store(version, fetched_at), do: :persistent_term.put(@key, {version, fetched_at})

  defp fetch do
    # Unauthenticated, so GitHub allows 60/hour per IP — a daily refresh sits far
    # under it even with every cold start counted.
    case Req.get(@api, receive_timeout: @cold_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: %{"tag_name" => "v" <> version}}} -> {:ok, version}
      {:ok, %{status: 200, body: %{"tag_name" => tag}}} -> {:ok, tag}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end

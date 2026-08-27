defmodule Codrift.Updater.Runner do
  @moduledoc """
  Runs one in-app update at a time and keeps its progress readable by the UI.

  ## Why the update finishes outside this process

  Both supported install shapes end with a shell script that this app *detaches*
  and then quits for, rather than with work done inline:

    * **Homebrew.** `Casks/codrift.rb` carries `uninstall quit: "app.codrift.desktop"`,
      so `brew upgrade` sends the running Codrift a quit event partway through.
      That quit tears down the Tauri shell, which kills the sidecar, which would
      kill `brew` itself if brew were a child of ours — leaving a half-upgraded
      cask. Detaching first is not a nicety, it is the only ordering that works.

    * **Self-managed.** A bundle cannot be swapped into place and relaunched by a
      process running out of it: `open -n` on the still-running app is answered
      by the single-instance plugin focusing the old window instead of starting
      the new one.

  So the script waits for this OS process to disappear, does the swap (or the
  `brew upgrade`), and reopens Codrift. The download and its checksum check stay
  here, in Elixir, where failures can still be shown to the user.

  ## Lifecycle

  `:idle → :running → :done | :failed`. `:done` means "quit now" — see
  `quit_required` in `status/0`. There is no going back to `:idle`; the window
  is on its way out.
  """

  use GenServer

  alias Codrift.Paths
  alias Codrift.Updater

  require Logger

  @type stage :: :idle | :running | :done | :failed

  @doc "Starts the runner. One per node; registered under its own module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @doc """
  Kicks off an update for `version`, using `assets` from the release that
  published it.

  `{:error, :busy}` when one is already running — the button is disabled while
  it is, but a second window (or a second click) must not start a second
  download over the same staging directory.
  """
  @spec start(Updater.version(), %{String.t() => String.t()}) ::
          {:ok, stage} | {:error, :busy | String.t()}
  def start(version, assets), do: GenServer.call(__MODULE__, {:start, version, assets}, 15_000)

  @doc """
  Progress for the UI: stage, the log lines produced so far, and — once the
  stage is `:done` — whether the app has to quit for the update to land.
  """
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(:ok), do: {:ok, blank()}

  defp blank do
    %{stage: :idle, mode: nil, version: nil, log: [], error: nil, task: nil}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call({:start, _version, _assets}, _from, %{stage: :running} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:start, version, assets}, _from, state) do
    app = Updater.app_path()

    case Updater.app_manager(app) do
      :unknown ->
        {:reply, {:error, "this build cannot update itself — install Codrift from a release"},
         state}

      mode ->
        task = spawn_run(mode, version, assets, app)

        {:reply, {:ok, :running},
         %{blank() | stage: :running, mode: mode, version: version, task: task}}
    end
  end

  defp spawn_run(mode, version, assets, app) do
    runner = self()
    Task.async(fn -> run(mode, version, assets, app, &send(runner, {:log, &1})) end)
  end

  @impl true
  def handle_info({:log, line}, state) do
    {:noreply, %{state | log: state.log ++ [line]}}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        {:noreply, %{state | stage: :done, task: nil}}

      {:error, reason} ->
        {:noreply, %{state | stage: :failed, error: reason, task: nil}}

      # A step that returned something other than `:ok`/`{:error, _}` — a bug,
      # but crashing here would leave the UI polling a `:running` that never
      # moves, which is the one outcome the user cannot recover from.
      other ->
        Logger.error("update returned an unexpected result: #{inspect(other)}")
        {:noreply, %{state | stage: :failed, error: "the update ended unexpectedly", task: nil}}
    end
  end

  # The work crashed rather than returning an error. Say so instead of leaving
  # the UI polling a `:running` that will never move again.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("update task crashed: #{inspect(reason)}")

    {:noreply,
     %{state | stage: :failed, error: "the update crashed: #{inspect(reason)}", task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp public(state) do
    %{
      "stage" => Atom.to_string(state.stage),
      "mode" => state.mode && Atom.to_string(state.mode),
      "version" => state.version,
      "log" => state.log,
      "error" => state.error,
      # Nothing has actually changed on disk until the app is gone and the
      # handoff script has run, so `:done` is a request, not a result.
      "quit_required" => state.stage == :done,
      "log_path" => log_path()
    }
  end

  # ── The update itself ──────────────────────────────────────────────────────

  defp run(:homebrew, version, _assets, app, log) do
    case Updater.brew_executable() do
      nil ->
        {:error,
         "Codrift was installed with Homebrew, but `brew` is not on this machine's PATH " <>
           "any more. Run `#{Updater.brew_upgrade_command()}` from a terminal."}

      brew ->
        log.("Handing #{version} to Homebrew: #{Updater.brew_upgrade_command()}")
        log.("Codrift has to close while brew works — it reopens on its own when done.")
        detach(brew_script(brew, app), log)
    end
  end

  defp run(:self, version, assets, app, log) do
    with {:ok, target} <- Updater.detect_target(),
         {:ok, {name, url}} <- asset(assets, target, version),
         :ok <- fetch(url, staged_download(name), name, log),
         {:ok, staged} <- stage(staged_download(name), app, log),
         :ok <- update_cli(version, log) do
      log.("Ready. Codrift restarts into #{version} as soon as it closes.")
      detach(swap_script(app, staged), log)
    end
  end

  defp asset(assets, target, version) do
    case Updater.desktop_asset(assets, target) do
      {:ok, found} -> {:ok, found}
      :error -> {:error, "release #{version} has no #{target} bundle to install"}
    end
  end

  defp fetch(url, dest, name, log) do
    log.("Downloading #{name}…")
    File.rm_rf(work_dir())

    case Updater.download_and_verify(url, dest) do
      :ok ->
        log.("Checksum verified.")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # macOS ships a disk image; Linux a single executable. Either way the result
  # is a fully-formed replacement sitting *next to* the live one, so a failure
  # here has still touched nothing the user is running.
  defp stage(archive, app, log) do
    case :os.type() do
      {:unix, :darwin} -> stage_dmg(archive, app, log)
      _ -> stage_appimage(archive, log)
    end
  end

  defp stage_dmg(dmg, app, log) do
    mount = Path.join(work_dir(), "mnt")
    File.mkdir_p!(mount)
    log.("Opening the disk image…")

    attach =
      System.cmd("/usr/bin/hdiutil", ["attach", dmg, "-nobrowse", "-quiet", "-mountpoint", mount],
        stderr_to_stdout: true
      )

    case attach do
      {_, 0} ->
        # Detached whatever happens: a mounted image left behind survives the
        # app quitting and shows up in Finder as a stray volume.
        result = copy_mounted_app(mount, Path.join(work_dir(), Path.basename(app)), log)
        System.cmd("/usr/bin/hdiutil", ["detach", mount, "-quiet"], stderr_to_stdout: true)
        result

      {out, _} ->
        {:error, "could not open the disk image: #{String.trim(out)}"}
    end
  end

  defp copy_mounted_app(mount, staged, log) do
    case Path.wildcard(Path.join(mount, "*.app")) do
      [bundle | _] ->
        log.("Copying #{Path.basename(bundle)}…")
        copy_bundle(bundle, staged)

      [] ->
        {:error, "the downloaded disk image contains no application"}
    end
  end

  defp copy_bundle(bundle, staged) do
    File.rm_rf(staged)

    case System.cmd("/bin/cp", ["-R", bundle, staged], stderr_to_stdout: true) do
      {_, 0} ->
        # Codrift ships unsigned, and anything downloaded carries the quarantine
        # flag Gatekeeper refuses to launch — the same strip the cask does in its
        # postflight. Best-effort: a signed build will not need it.
        System.cmd("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged],
          stderr_to_stdout: true
        )

        {:ok, staged}

      {out, _} ->
        {:error, "could not unpack the update: #{String.trim(out)}"}
    end
  end

  defp stage_appimage(image, log) do
    log.("Preparing the AppImage…")
    File.chmod!(image, 0o755)
    {:ok, image}
  end

  # The app and the `codrift` command are separate installs that drift apart if
  # only one moves — which is the same complaint the cask's caveats make about
  # `brew upgrade codrift` on its own. Never fatal: a failed CLI update must not
  # cost the user the app update they asked for.
  defp update_cli(version, log) do
    case Updater.cli_manager() do
      :self ->
        dir = Updater.cli_install_dir()
        log.("Updating the codrift command in #{Paths.compact(dir)}…")

        case Updater.install(version, dir) do
          :ok ->
            :ok

          {:error, reason} ->
            log.("Could not update the codrift command: #{reason}")
            :ok
        end

      _ ->
        :ok
    end
  end

  # ── Handoff ────────────────────────────────────────────────────────────────

  # Runs `script` with no controlling terminal and no parent left to be killed
  # with us: `sh -c` returns the moment it has backgrounded the child, and the
  # child is reparented to init. Tauri's shutdown only signals the sidecar's own
  # pid, so nothing in that path can reach the script afterwards.
  defp detach(script, log) do
    path = Path.join(work_dir(), "handoff.sh")
    File.mkdir_p!(work_dir())
    File.write!(path, script)
    File.chmod!(path, 0o755)

    command = "nohup #{quote_sh(path)} >#{quote_sh(log_path())} 2>&1 &"

    case System.cmd("/bin/sh", ["-c", command], stderr_to_stdout: true) do
      {_, 0} ->
        log.("Log: #{Paths.compact(log_path())}")
        :ok

      {out, code} ->
        {:error, "could not start the update helper (exit #{code}): #{String.trim(out)}"}
    end
  end

  @doc """
  The script that hands the upgrade to Homebrew once this process is gone.

  Public so it can be asserted on: the ordering it encodes — wait for the app to
  exit, *then* upgrade, *then* reopen — is the whole reason the update works at
  all, and it is not reachable from a test through `start/2` without a network.
  """
  @spec brew_script(String.t(), String.t()) :: String.t()
  def brew_script(brew, app) do
    """
    #!/bin/sh
    #{wait_for_exit()}
    #{quote_sh(brew)} upgrade #{brew_targets()}
    status=$?
    echo "brew exited with ${status}"
    #{relaunch(app)}
    """
  end

  defp brew_targets do
    Updater.brew_upgrade_command()
    |> String.replace_prefix("brew upgrade ", "")
  end

  @doc """
  The script that moves the downloaded bundle into place and reopens Codrift.

  Public for the same reason as `brew_script/2`. The two `mv`s are deliberate:
  the live bundle is only ever renamed aside, never deleted, so a failed second
  move can put it back rather than leave the user with no Codrift at all.
  """
  @spec swap_script(String.t(), String.t()) :: String.t()
  def swap_script(app, staged) do
    """
    #!/bin/sh
    #{wait_for_exit()}
    set -e
    rm -rf #{quote_sh(app <> ".old")}
    mv #{quote_sh(app)} #{quote_sh(app <> ".old")}
    # Put the previous version back rather than leave the user with no Codrift
    # at all if the second move is the one that fails.
    mv #{quote_sh(staged)} #{quote_sh(app)} || { mv #{quote_sh(app <> ".old")} #{quote_sh(app)}; exit 1; }
    rm -rf #{quote_sh(app <> ".old")}
    #{relaunch(app)}
    """
  end

  # The handoff must not start before this process is gone: on macOS `open -n`
  # against a still-running bundle is swallowed by the single-instance plugin,
  # and on either platform the swap would race the app's own shutdown. Capped so
  # a wedged shutdown ends in a stale script exiting, not one spinning forever.
  defp wait_for_exit do
    """
    n=0
    while [ $n -lt 120 ] && kill -0 #{System.pid()} 2>/dev/null; do
      sleep 0.5
      n=$((n+1))
    done
    """
    |> String.trim_trailing()
  end

  defp relaunch(app) do
    case :os.type() do
      {:unix, :darwin} -> "open -n #{quote_sh(app)}"
      _ -> "#{quote_sh(app)} >/dev/null 2>&1 &"
    end
  end

  defp staged_download(name), do: Path.join(work_dir(), name)
  defp work_dir, do: Path.join(Paths.data_dir(), "update")

  @doc "Where the detached helper writes what it did, for after the app is gone."
  @spec log_path() :: String.t()
  def log_path, do: Path.join(Paths.data_dir(), "update.log")

  # Single-quote for /bin/sh: everything is literal inside single quotes, so the
  # only case to handle is a quote itself. Paths here come from the environment
  # and from GitHub asset names, neither of which is ours to trust unquoted.
  defp quote_sh(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

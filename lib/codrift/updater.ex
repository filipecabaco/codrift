defmodule Codrift.Updater do
  @moduledoc """
  Version checking and self-update logic.

  All functions are pure/side-effect-free except for `fetch_latest_version/0`
  (HTTP) and `install/1` (filesystem). The TUI uses `check_async/1` to fire
  a non-blocking version probe on startup.
  """

  @repo "filipecabaco/codrift"

  # Where install.sh puts the release when nothing better is known. NOT expanded
  # here: a module attribute is evaluated at compile time, so `Path.expand/1` at
  # this level bakes the *build machine's* home into every published binary —
  # which is how every shipped `codrift update` came to try, and fail, to write
  # to the CI runner's `/Users/runner/.local/share/codrift`. Expansion happens in
  # `install_dir/0`, at runtime, on the user's machine.
  @default_install_dir "~/.local/share/codrift"

  @type version :: String.t()
  @type check_result ::
          {:up_to_date, version} | {:update_available, version, version} | {:error, String.t()}

  @typedoc """
  Who owns an installed copy, and therefore who is allowed to replace it.

  `:unknown` is not "probably self" — it is "we could not tell", which is the
  answer whenever the desktop shell did not hand us `CODRIFT_APP_PATH`
  (`mix ex_tauri.dev`, a plain `mix francis.server`). Nothing self-replaces on
  an `:unknown`.
  """
  @type manager :: :homebrew | :self | :unknown

  @doc "Returns the version compiled into the running release."
  @spec current_version() :: version
  def current_version do
    case :application.get_key(:codrift, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "dev"
    end
  end

  @doc "Fetches the latest published version tag from GitHub releases."
  @spec fetch_latest_version() :: {:ok, version} | {:error, String.t()}
  def fetch_latest_version do
    with {:ok, %{version: version}} <- fetch_latest_release(), do: {:ok, version}
  end

  @doc """
  The latest release's version *and* its published assets, as a
  `%{name => download_url}` map.

  The desktop bundles are named by the Tauri bundler, not by us
  (`Codrift_<version>_aarch64.dmg`, `Codrift_<version>_amd64.AppImage`), and
  that naming has changed with bundler versions. Reading the real asset list and
  matching a pattern against it means a rename in CI cannot silently turn every
  in-app update into a 404 the way a hardcoded filename would.
  """
  @spec fetch_latest_release() ::
          {:ok, %{version: version, assets: %{String.t() => String.t()}}} | {:error, String.t()}
  def fetch_latest_release do
    url = "https://api.github.com/repos/#{@repo}/releases/latest"

    case Req.get(url, headers: [{"user-agent", "codrift/#{current_version()}"}]) do
      {:ok, %{status: 200, body: %{"tag_name" => tag} = body}} ->
        {:ok, %{version: String.trim_leading(tag, "v"), assets: assets_map(body)}}

      {:ok, %{status: 404}} ->
        {:error, "no releases found"}

      {:ok, %{status: status}} ->
        {:error, "GitHub API returned #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp assets_map(%{"assets" => assets}) when is_list(assets) do
    Map.new(assets, fn asset ->
      {asset["name"], asset["browser_download_url"]}
    end)
  end

  defp assets_map(_), do: %{}

  @doc """
  Picks the desktop bundle for `target` out of a release's asset names.

  Matching is by shape rather than by exact name for the reason given on
  `fetch_latest_release/0`. Returns `{:ok, {name, url}}` or `:error` when the
  release carries nothing this platform can install.
  """
  @spec desktop_asset(%{String.t() => String.t()}, String.t()) ::
          {:ok, {String.t(), String.t()}} | :error
  def desktop_asset(assets, target) do
    case bundle_pattern(target) do
      nil ->
        :error

      pattern ->
        assets
        |> Enum.filter(fn {name, _url} -> Regex.match?(pattern, name) end)
        |> Enum.sort()
        |> case do
          [{name, url} | _] -> {:ok, {name, url}}
          [] -> :error
        end
    end
  end

  defp bundle_pattern("aarch64-apple-darwin"), do: ~r/(aarch64|arm64)\.dmg$/i
  defp bundle_pattern("x86_64-apple-darwin"), do: ~r/(x64|x86_64|intel)\.dmg$/i
  defp bundle_pattern("aarch64-linux-gnu"), do: ~r/(aarch64|arm64)\.AppImage$/i
  defp bundle_pattern("x86_64-linux-gnu"), do: ~r/(amd64|x86_64|x64)\.AppImage$/i
  defp bundle_pattern(_), do: nil

  @doc "The platform triple this build runs on, e.g. `aarch64-apple-darwin`."
  @spec detect_target() :: {:ok, String.t()} | {:error, String.t()}
  def detect_target do
    os = :os.type()
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    case {os, arch} do
      {{:unix, :darwin}, a} when is_binary(a) ->
        if String.contains?(a, "aarch64"),
          do: {:ok, "aarch64-apple-darwin"},
          else: {:ok, "x86_64-apple-darwin"}

      {{:unix, _}, a} when is_binary(a) ->
        if String.contains?(a, "aarch64"),
          do: {:ok, "aarch64-linux-gnu"},
          else: {:ok, "x86_64-linux-gnu"}

      _ ->
        {:error, "unsupported platform"}
    end
  end

  @doc "Compares current vs latest and returns a structured result."
  @spec check() :: check_result
  def check do
    current = current_version()

    case fetch_latest_version() do
      {:ok, latest} ->
        cond do
          current == "dev" -> {:up_to_date, current}
          Version.compare(latest, current) == :gt -> {:update_available, current, latest}
          true -> {:up_to_date, current}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fires an async version check and sends `{:update_available, latest}` to
  `pid` if a newer version exists. Silently swallows errors.
  """
  @spec check_async(pid) :: :ok
  def check_async(pid) do
    Task.start(fn ->
      case check() do
        {:update_available, _current, latest} -> send(pid, {:update_available, latest})
        _ -> :ok
      end
    end)

    :ok
  end

  @doc """
  The release tree this command is running out of, and the tree an update
  replaces.

  Prefers `RELEASE_ROOT`, which the mix release boot script derives from the
  real location of `bin/codrift` (following the symlink that landed on PATH).
  That is the only source of truth: the same CLI is installed to
  `~/.local/share/codrift` by install.sh and to a Homebrew Cellar prefix by the
  `codrift-cli` formula, and writing to the wrong one leaves the binary that is
  actually on PATH untouched — an update that reports success and changes
  nothing. Falls back to install.sh's location outside a release (dev, tests).
  """
  @spec install_dir() :: String.t()
  def install_dir, do: install_dir(System.get_env("RELEASE_ROOT"))

  @doc "`install_dir/0` with the release root passed in, so it can be tested."
  @spec install_dir(String.t() | nil) :: String.t()
  def install_dir(root) when is_binary(root) and root != "", do: root
  def install_dir(_), do: Path.expand(@default_install_dir)

  @doc """
  The CLI's release tree as seen from *another* process — the desktop sidecar,
  which updates the `codrift` command alongside the app.

  `install_dir/0` cannot answer this there: inside the app, `RELEASE_ROOT` is the
  sidecar's own Burrito unpack directory, so it would have the app happily
  "update the CLI" by overwriting a cache folder. Follows the `codrift` on PATH
  back to the release root that contains it instead, and only accepts it when it
  actually looks like one.
  """
  @spec cli_install_dir() :: String.t()
  def cli_install_dir do
    with path when is_binary(path) <- System.find_executable("codrift"),
         root = path |> resolve_link() |> Path.dirname() |> Path.dirname(),
         true <- File.dir?(Path.join(root, "releases")) do
      root
    else
      _ -> Path.expand(@default_install_dir)
    end
  end

  @doc """
  The `.app` bundle (macOS) or AppImage (Linux) this window is running out of,
  or `nil` when that is not knowable.

  Read from `CODRIFT_APP_PATH`, which the Tauri shell derives from its own
  executable and hands to the sidecar. Deliberately *not* derived here from
  `RELEASE_ROOT` or `__BURRITO_BIN_PATH`: Burrito unpacks the release into
  `~/Library/Application Support/.burrito/…` and runs from there, so the release
  root points at a cache directory that has nothing to do with the bundle a user
  would drag to the Trash. Nothing else on the BEAM side knows where the app is.
  """
  @spec app_path() :: String.t() | nil
  def app_path do
    case System.get_env("CODRIFT_APP_PATH") do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  @doc """
  Who owns the app bundle at `path`.

  Biased towards `:homebrew` on purpose. The two failure directions are not
  symmetrical: calling a Homebrew install `:self` means replacing a Cellar/cask
  tree underneath brew — corrupting its manifest, and reverted by the next
  `brew upgrade` anyway — while calling a manual install `:homebrew` merely runs
  a `brew upgrade` that reports the cask is not installed. So the presence of a
  `codrift` cask receipt anywhere is enough, without checking whether *this*
  bundle is the one it installed.
  """
  @spec app_manager(String.t() | nil) :: manager
  def app_manager(path)
  def app_manager(nil), do: :unknown
  def app_manager(""), do: :unknown

  def app_manager(path) do
    cond do
      "Caskroom" in Path.split(path) -> :homebrew
      cask_receipt?() -> :homebrew
      true -> :self
    end
  end

  @doc """
  Who owns the `codrift` command on PATH — which is a different question from
  `app_manager/1`, because the app and the CLI ship as a cask and a formula that
  can be installed independently (and `install.sh` installs both outside brew).

  `:missing` when there is no `codrift` on PATH at all; nothing to upgrade.
  """
  @spec cli_manager() :: manager | :missing
  def cli_manager do
    case System.find_executable("codrift") do
      nil -> :missing
      path -> if "Cellar" in Path.split(resolve_link(path)), do: :homebrew, else: :self
    end
  end

  @doc """
  The `brew upgrade` line that moves a Homebrew install forward, naming only the
  packages brew actually owns.

  The cask `depends_on` the formula but `brew upgrade codrift` bumps the cask
  alone — brew does not upgrade a cask's formula dependencies — so both names
  have to appear, which is what `Casks/codrift.rb`'s caveats tell users too.
  """
  @spec brew_upgrade_command() :: String.t()
  def brew_upgrade_command do
    names = ["codrift"] ++ if(cli_manager() == :homebrew, do: ["codrift-cli"], else: [])
    "brew upgrade " <> Enum.join(names, " ")
  end

  @doc "Absolute path to `brew`, or `nil` when it is not installed/on PATH."
  @spec brew_executable() :: String.t() | nil
  def brew_executable do
    Enum.find_value(
      [System.find_executable("brew"), "/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
      fn candidate -> if is_binary(candidate) and File.regular?(candidate), do: candidate end
    )
  end

  # Homebrew keeps one directory per installed cask under `<prefix>/Caskroom`,
  # and it survives the app being moved to /Applications (which is where the
  # `app` stanza puts it), so it is the durable record that brew owns Codrift.
  # The env vars are read first for a non-standard prefix, but a GUI app started
  # from Finder rarely has them — hence the two literal defaults.
  defp cask_receipt? do
    [
      System.get_env("HOMEBREW_CASKROOM"),
      with(
        prefix when is_binary(prefix) <- System.get_env("HOMEBREW_PREFIX"),
        do: Path.join(prefix, "Caskroom")
      ),
      "/opt/homebrew/Caskroom",
      "/usr/local/Caskroom"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&File.dir?(Path.join(&1, "codrift")))
  end

  @doc """
  Detects a release tree owned by an external package manager, which self-update
  must not overwrite.

  Homebrew tracks the files it installed; replacing a Cellar prefix underneath it
  corrupts that manifest and the next `brew upgrade` reverts the change anyway.
  Returns `{:ok, instructions}` for such a tree, `:error` when self-update owns it.
  """
  @spec external_package_manager(String.t()) :: {:ok, String.t()} | :error
  def external_package_manager(dir) do
    if "Cellar" in Path.split(dir) do
      {:ok, "brew upgrade codrift codrift-cli"}
    else
      :error
    end
  end

  @doc """
  Returns `{:ok, path}` when the `codrift` that PATH resolves to lives outside
  `dir`, i.e. an update to `dir` will not be the one that runs.

  Two installers write this command — install.sh to `~/.local/bin` and the
  `codrift-cli` formula to Homebrew's `bin` — and whichever comes first on PATH
  wins. Updating the loser is silent: `codrift version` keeps reporting the old
  number and the update looks broken.
  """
  @spec shadowing_binary(String.t()) :: {:ok, String.t()} | :none
  def shadowing_binary(dir) do
    prefix = String.trim_trailing(dir, "/") <> "/"

    with path when is_binary(path) <- System.find_executable("codrift"),
         false <- String.starts_with?(resolve_link(path), prefix) do
      {:ok, path}
    else
      _ -> :none
    end
  end

  @doc """
  Downloads and installs the given version for the current platform, replacing
  the release tree returned by `install_dir/0`. Any symlink on PATH stays valid
  since it points into that directory.

  The tarball's SHA-256 is verified against the `.sha256` asset published next
  to it, and the tarball is unpacked into a sibling staging directory, before
  anything in the live tree is touched.

  Refuses to touch a Homebrew-managed tree — see `external_package_manager/1`.
  """
  @spec install(version) :: :ok | {:error, String.t()}
  def install(version), do: install(version, install_dir())

  @doc "`install/1` against an explicit install directory."
  @spec install(version, String.t()) :: :ok | {:error, String.t()}
  def install(version, dir) do
    with :ok <- ensure_self_managed(dir),
         {:ok, target} <- detect_target(),
         {:ok, tmp_path} <- download(version, target),
         :ok <- install_tarball(tmp_path, dir) do
      File.rm(tmp_path)
      :ok
    end
  end

  @doc """
  Unpacks a verified CLI tarball into `dir`, replacing whatever is there.

  Extraction goes to `<dir>.new` and is swapped in with two renames, so the old
  tree is never removed before a complete new one exists beside it: a truncated
  download, a bad archive or a killed process leaves the working install intact
  rather than half-replaced. That matters more than usual here — this process is
  executing out of the very tree being replaced.
  """
  @spec install_tarball(String.t(), String.t()) :: :ok | {:error, String.t()}
  def install_tarball(tarball_path, dir) do
    staging = dir <> ".new"
    previous = dir <> ".old"

    with :ok <- reset_dir(staging),
         :ok <- untar(tarball_path, staging),
         :ok <- verify_release_tree(staging),
         :ok <- reset_dir(previous, :remove_only),
         :ok <- swap(dir, staging, previous) do
      File.rm_rf(previous)
      :ok
    else
      {:error, reason} ->
        File.rm_rf(staging)
        {:error, reason}
    end
  end

  @doc """
  CLI tarball asset name for a release, e.g.
  `codrift-cli-0.1.0-x86_64-linux-gnu.tar.gz`.

  Must match the asset naming in `.github/workflows/release.yml` (the
  "Rename CLI tarball" step) and the pattern `install.sh` greps for.
  """
  @spec cli_asset(version, String.t()) :: String.t()
  def cli_asset(version, target), do: "codrift-cli-#{version}-#{target}.tar.gz"

  @doc "Download URL for the CLI tarball of a released version."
  @spec cli_asset_url(version, String.t()) :: String.t()
  def cli_asset_url(version, target) do
    "https://github.com/#{@repo}/releases/download/v#{version}/#{cli_asset(version, target)}"
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp download(version, target) do
    url = cli_asset_url(version, target)
    tmp = Path.join(System.tmp_dir!(), cli_asset(version, target))

    with :ok <- download_and_verify(url, tmp), do: {:ok, tmp}
  end

  @doc """
  Downloads `url` to `dest` and verifies it against the `<url>.sha256` asset
  published beside it, deleting `dest` on a mismatch.

  Every published asset gets a sibling checksum (release.yml's "Collect release
  assets" step), and both `install.sh` and every path that installs a downloaded
  artifact go through this — an unsigned build is the only integrity check
  there is, so a missing checksum file is an error rather than a skip.
  """
  @spec download_and_verify(String.t(), String.t()) :: :ok | {:error, String.t()}
  def download_and_verify(url, dest) do
    File.mkdir_p!(Path.dirname(dest))

    case Req.get(url, into: File.stream!(dest)) do
      {:ok, %{status: 200}} -> verify_checksum(dest, url <> ".sha256")
      {:ok, %{status: 404}} -> {:error, "release not found: #{url}"}
      {:ok, %{status: s}} -> {:error, "download failed with status #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # Fetches the published `.sha256` and compares it to the local file's digest.
  # The checksum file contains `<hex>  <filename>` (the `shasum`/`sha256sum`
  # format emitted by release.yml).
  defp verify_checksum(path, url) do
    with {:ok, %{status: 200, body: body}} <- Req.get(url),
         [expected | _] <- body |> to_string() |> String.split() do
      actual =
        :sha256
        |> :crypto.hash(File.read!(path))
        |> Base.encode16(case: :lower)

      if actual == String.downcase(expected) do
        :ok
      else
        File.rm(path)

        {:error,
         "checksum mismatch for #{Path.basename(path)}: expected #{expected}, got #{actual}"}
      end
    else
      {:ok, %{status: s}} -> {:error, "checksum file unavailable (status #{s}): #{url}"}
      {:error, reason} -> {:error, inspect(reason)}
      [] -> {:error, "checksum file is empty: #{url}"}
    end
  end

  # Both installers put a symlink on PATH rather than the launcher itself
  # (`~/.local/bin/codrift` and Homebrew's `bin/codrift`), so the raw PATH hit
  # never sits inside the release tree. One hop is enough for both.
  defp resolve_link(path) do
    case File.read_link(path) do
      {:ok, target} -> Path.expand(target, Path.dirname(path))
      {:error, _} -> path
    end
  end

  defp ensure_self_managed(dir) do
    case external_package_manager(dir) do
      {:ok, command} ->
        {:error, "#{dir} is managed by Homebrew — run `#{command}` instead of `codrift update`."}

      :error ->
        :ok
    end
  end

  defp reset_dir(path, mode \\ :recreate) do
    with {:ok, _} <- File.rm_rf(path),
         :ok <- if(mode == :recreate, do: File.mkdir_p(path), else: :ok) do
      :ok
    else
      {:error, reason, file} ->
        {:error, "could not remove #{file}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, "could not create #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp untar(tarball_path, into) do
    opts = [:compressed, {:cwd, String.to_charlist(into)}]

    case :erl_tar.extract(String.to_charlist(tarball_path), opts) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not unpack the release: #{inspect(reason)}"}
    end
  end

  # A mix release tarball has bin/, lib/, erts-* and releases/ at its root with
  # no wrapping directory. Checking for the launcher catches a truncated or
  # differently-shaped asset while the live tree is still intact.
  defp verify_release_tree(dir) do
    if File.regular?(Path.join([dir, "bin", "codrift"])),
      do: :ok,
      else: {:error, "downloaded archive does not contain bin/codrift"}
  end

  defp swap(dir, staging, previous) do
    # A first install has nothing to move aside; only a real failure is an error.
    case File.rename(dir, previous) do
      :ok -> rename_into_place(staging, dir, previous)
      {:error, :enoent} -> rename_into_place(staging, dir, nil)
      {:error, reason} -> {:error, "could not move #{dir} aside: #{:file.format_error(reason)}"}
    end
  end

  defp rename_into_place(staging, dir, moved_aside) do
    case File.rename(staging, dir) do
      :ok ->
        :ok

      {:error, reason} ->
        # Both renames are within one parent directory, so reaching here means
        # something outside our control took the path. Put the old tree back
        # rather than leave the user with no `codrift` at all.
        if moved_aside, do: File.rename(moved_aside, dir)
        {:error, "could not install to #{dir}: #{:file.format_error(reason)}"}
    end
  end
end

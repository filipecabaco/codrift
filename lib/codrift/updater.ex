defmodule Codrift.Updater do
  @moduledoc """
  Version checking and self-update logic.

  All functions are pure/side-effect-free except for `fetch_latest_version/0`
  (HTTP) and `install/1` (filesystem). The TUI uses `check_async/1` to fire
  a non-blocking version probe on startup.
  """

  @repo "filipecabaco/codrift"
  @install_dir Path.expand("~/.local/share/codrift")

  @type version :: String.t()
  @type check_result ::
          {:up_to_date, version} | {:update_available, version, version} | {:error, String.t()}

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
    url = "https://api.github.com/repos/#{@repo}/releases/latest"

    case Req.get(url, headers: [{"user-agent", "codrift/#{current_version()}"}]) do
      {:ok, %{status: 200, body: %{"tag_name" => tag}}} ->
        {:ok, String.trim_leading(tag, "v")}

      {:ok, %{status: 404}} ->
        {:error, "no releases found"}

      {:ok, %{status: status}} ->
        {:error, "GitHub API returned #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "Compares current vs latest and returns a structured result."
  @spec check() :: check_result
  def check do
    current = current_version()

    case fetch_latest_version() do
      {:ok, latest} ->
        if current == latest or current == "dev",
          do: {:up_to_date, current},
          else: {:update_available, current, latest}

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
  Downloads and installs the given version for the current platform.
  Replaces `~/.local/share/codrift` in-place. The `~/.local/bin/codrift`
  symlink remains valid since it already points to that directory.
  """
  @spec install(version) :: :ok | {:error, String.t()}
  def install(version) do
    with {:ok, target} <- detect_target(),
         {:ok, tmp_path} <- download(version, target),
         :ok <- extract(tmp_path) do
      File.rm(tmp_path)
      :ok
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp detect_target do
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

  defp download(version, target) do
    tarball = "codrift-#{version}-#{target}.tar.gz"
    url = "https://github.com/#{@repo}/releases/download/v#{version}/#{tarball}"
    tmp = Path.join(System.tmp_dir!(), tarball)

    case Req.get(url, into: File.stream!(tmp)) do
      {:ok, %{status: 200}} -> {:ok, tmp}
      {:ok, %{status: 404}} -> {:error, "release not found: #{url}"}
      {:ok, %{status: s}} -> {:error, "download failed with status #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp extract(tarball_path) do
    install_dir = String.to_charlist(@install_dir)

    File.rm_rf!(@install_dir)
    File.mkdir_p!(@install_dir)

    case :erl_tar.extract(String.to_charlist(tarball_path), [:compressed, {:cwd, install_dir}]) do
      :ok -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end

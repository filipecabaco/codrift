defmodule Codrift.CLI.MCP do
  @moduledoc """
  CLI implementation for MCP server registration.

  The Mix task (`mix codrift.mcp.install`) delegates to this module, and the
  release command (`codrift mcp install`) calls it via `eval`.

  ## Usage

      codrift mcp install [--port=43117]
      codrift mcp install --profile=<name>
      codrift mcp install --all-profiles
      codrift mcp status  [--profile=<name> | --all-profiles]

  Registers the Codrift SSE endpoint with every detected AI CLI:

    - **Claude Code** — `claude mcp add --scope user --transport sse`
    - **Gemini CLI** — merges `mcpServers` into `~/.gemini/settings.json`
    - **Opencode** — merges `mcp` block into `~/.config/opencode/opencode.jsonc`
    - **Cursor CLI** — merges `mcpServers` into `~/.cursor/mcp.json`
    - **Codex** — prints manual instructions (it only speaks streamable HTTP)
    - **Copilot** — prints manual instructions (gh copilot has no MCP config)

  Editing someone else's config file is destructive, so every write pretty-
  prints (a minified one-liner is not a config a human can keep maintaining),
  leaves a `.bak` sibling, and warns when a JSONC round-trip drops comments.

  ## Launch profiles

  A profile that sets `CLAUDE_CONFIG_DIR` gives its agents a *different* config
  directory, and `claude mcp add --scope user` writes to whichever one is in the
  environment when it runs. So a plain `codrift mcp install` registers Codrift
  for the default config and for nothing else: agents launched under that
  profile start up with no Codrift tools at all, which reads as "the MCP server
  is broken" rather than "it was never installed here".

  `--profile=<name>` re-runs the registration with that profile's environment,
  and `--all-profiles` does every profile in `settings.json`. Both are additive
  — the default registration is untouched — so the usual sequence is:

      codrift mcp install
      codrift mcp install --all-profiles

  `codrift mcp status --all-profiles` says which of them actually took.
  """

  alias Codrift.Config.Settings

  @server_name "codrift"
  @default_port 43_117

  @doc "Dispatches MCP CLI subcommands from argv."
  @spec run([String.t()]) :: :ok
  def run(["install" | args]), do: install(args)
  def run(["status" | args]), do: status(args)

  def run(_) do
    IO.puts("""
    Usage:
      codrift mcp install [--port=<port>]     Register with every detected AI CLI
      codrift mcp install --profile=<name>    Register for one launch profile
      codrift mcp install --all-profiles      Register for every launch profile
      codrift mcp status [--all-profiles]     Report what is registered where

    A launch profile that sets CLAUDE_CONFIG_DIR has its own config directory,
    which a plain install never touches. Agents started under it would come up
    with no Codrift tools, so install for the default AND for the profiles:

      codrift mcp install
      codrift mcp install --all-profiles
    """)
  end

  # ── Subcommands ──────────────────────────────────────────────────────────────

  defp install(args) do
    port = resolve_port(args)
    sse_url = "http://localhost:#{port}/mcp/sse"
    # State-changing MCP calls must authenticate to the local server (see
    # Codrift.Plugs.LocalGuard); registrations embed the stable local token.
    token = Codrift.AuthToken.fetch()

    case profile_selection(args) do
      :default -> install_default(sse_url, token)
      {:profiles, []} -> IO.puts("No launch profiles configured in settings.json.")
      {:profiles, names} -> Enum.each(names, &install_for_profile(&1, sse_url, token))
    end
  end

  defp install_default(sse_url, token) do
    results = [
      install_claude(sse_url, token),
      install_gemini(sse_url, token),
      install_opencode(sse_url, token),
      install_cursor(sse_url, token),
      install_codex(sse_url),
      install_copilot(sse_url)
    ]

    if Enum.all?(results, &(&1 == :skip)) do
      IO.puts("""
      No supported AI CLIs found in PATH.

      Point any MCP-compatible client at the SSE endpoint:

          #{sse_url}

      and send the token from ~/.codrift/auth-token as an `X-Codrift-Token`
      header on requests.
      """)
    end

    if Settings.profiles() != %{} do
      IO.puts("""

      Launch profiles are configured. Any that set CLAUDE_CONFIG_DIR keep their
      own config directory, which the registration above did not touch:

          codrift mcp install --all-profiles
      """)
    end
  end

  # Re-runs the Claude Code registration inside one profile's environment.
  #
  # Only `CLAUDE_CONFIG_DIR` is honoured, because it is the only redirection
  # Codrift itself applies when launching a profile (see
  # `Codrift.AgentProcess.profile_config_dir/1`). A profile without it shares the
  # default config, so the plain install already covered it — saying so is more
  # useful than re-registering into the same file and calling it a success.
  defp install_for_profile(name, sse_url, token) do
    case Settings.profile(name) do
      {:error, :not_found} ->
        IO.puts("Profile #{name}: not found in settings.json - skipping")
        :skip

      {:ok, profile} ->
        case profile_config_dir(profile) do
          nil ->
            IO.puts(
              "Profile #{name}: no CLAUDE_CONFIG_DIR - shares the default config, " <>
                "already registered by `codrift mcp install`"
            )

            :skip

          dir ->
            IO.puts("Profile #{name}: registering in #{short(dir)}...")
            # `claude mcp add` writes into the directory; if the profile has never
            # been launched it does not exist yet, and the add would fail on a
            # path rather than on anything the user could act on.
            File.mkdir_p!(dir)
            install_claude(sse_url, token, [{"CLAUDE_CONFIG_DIR", dir}])
        end
    end
  end

  # ── Status ───────────────────────────────────────────────────────────────────

  defp status(args) do
    case profile_selection(args) do
      :default ->
        report_status("default", [])

      {:profiles, []} ->
        IO.puts("No launch profiles configured in settings.json.")

      {:profiles, names} ->
        report_status("default", [])
        Enum.each(names, &report_profile_status/1)
    end
  end

  defp report_profile_status(name) do
    case Settings.profile(name) do
      {:error, :not_found} -> IO.puts("#{name}: not found in settings.json")
      {:ok, profile} -> report_profile_dir(name, profile_config_dir(profile))
    end
  end

  # A profile with no directory of its own was covered by the default line
  # already printed above; saying which is more useful than repeating it.
  defp report_profile_dir(name, nil),
    do: IO.puts("#{name}: shares the default config (above)")

  defp report_profile_dir(name, dir),
    do: report_status(name, [{"CLAUDE_CONFIG_DIR", dir}])

  # `claude mcp list` rather than `mcp get`: the output format of `get` has moved
  # between releases, but the name appearing in the list has not.
  defp report_status(label, env) do
    case System.find_executable("claude") do
      nil ->
        IO.puts("#{label}: claude not found in PATH")

      _bin ->
        report_listing(
          label,
          System.cmd("claude", ["mcp", "list"], env: env, stderr_to_stdout: true)
        )
    end
  end

  defp report_listing(label, {output, 0}) do
    if registered?(output),
      do: IO.puts("#{label}: [ok] #{@server_name} registered"),
      else: IO.puts("#{label}: [missing] run `codrift mcp install#{flag_for(label)}`")
  end

  defp report_listing(label, {output, code}) do
    IO.puts("#{label}: [error] claude mcp list exited #{code}: #{String.trim(output)}")
  end

  # Anchored to the start of a listing line. A bare substring search would count
  # any server whose name merely contains "codrift" — including one pointing at
  # something else entirely — as this one being installed.
  @doc false
  @spec registered?(String.t()) :: boolean()
  def registered?(output) do
    output
    |> String.split("\n")
    |> Enum.any?(&String.starts_with?(String.trim_leading(&1), @server_name <> ":"))
  end

  defp flag_for("default"), do: ""
  defp flag_for(name), do: " --profile=#{name}"

  # ── Profile selection ────────────────────────────────────────────────────────

  @doc false
  @spec profile_selection([String.t()]) :: :default | {:profiles, [String.t()]}
  def profile_selection(args) do
    cond do
      "--all-profiles" in args ->
        {:profiles, Settings.profiles() |> Map.keys() |> Enum.sort()}

      flag = Enum.find(args, &String.starts_with?(&1, "--profile=")) ->
        {:profiles, [String.slice(flag, 10..-1//1)]}

      true ->
        :default
    end
  end

  # `~` is stored verbatim in settings.json so the file stays portable; it is
  # expanded at launch, and has to be expanded here for the same reason.
  @doc false
  @spec profile_config_dir(map()) :: String.t() | nil
  def profile_config_dir(profile) do
    case profile |> Map.get("env", %{}) |> Map.get("CLAUDE_CONFIG_DIR") do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> nil
    end
  end

  # ── Per-client installers ────────────────────────────────────────────────────

  defp install_claude(sse_url, token, env \\ []) do
    case System.find_executable("claude") do
      nil ->
        :skip

      _bin ->
        if env == [], do: IO.puts("Claude Code: registering via `claude mcp add`...")

        # `claude mcp add` refuses to overwrite an existing name, so a second
        # `codrift mcp install` would otherwise always fail. Scope is `user`
        # because the default (`local`) binds the server to the directory the
        # installer happened to run in.
        System.cmd("claude", ["mcp", "remove", @server_name, "--scope", "user"],
          env: env,
          stderr_to_stdout: true
        )

        args = [
          "mcp",
          "add",
          @server_name,
          "--scope",
          "user",
          "--transport",
          "sse",
          sse_url,
          "--header",
          "X-Codrift-Token: #{token}"
        ]

        case System.cmd("claude", args, env: env, stderr_to_stdout: true) do
          {output, 0} ->
            IO.puts("  ✓ #{String.trim(output)}")
            :ok

          {output, code} ->
            IO.puts("  ✗ claude mcp add exited #{code}: #{String.trim(output)}")

            IO.puts(
              "    Manual: claude mcp add #{@server_name} --scope user " <>
                "--transport sse #{sse_url}"
            )

            :error
        end
    end
  end

  # Gemini infers the transport from the key: `url` is SSE, `httpUrl` is
  # streamable HTTP. There is no `type` field.
  defp install_gemini(sse_url, token) do
    merge_config(
      "gemini",
      "Gemini CLI",
      Path.expand("~/.gemini/settings.json"),
      &JSON.decode!/1,
      %{},
      "mcpServers",
      %{"url" => sse_url, "headers" => %{"X-Codrift-Token" => token}}
    )
  end

  # Opencode validates its config against opencode.ai/config.json: `type` is
  # `local` | `remote`, and anything else makes the whole file fail to load.
  defp install_opencode(sse_url, token) do
    merge_config(
      "opencode",
      "Opencode",
      Path.expand("~/.config/opencode/opencode.jsonc"),
      &Codrift.JSONC.decode!/1,
      %{"$schema" => "https://opencode.ai/config.json"},
      "mcp",
      %{
        "type" => "remote",
        "url" => sse_url,
        "enabled" => true,
        "headers" => %{"X-Codrift-Token" => token}
      }
    )
  end

  # Cursor takes a remote server as a bare `url` plus optional `headers`; the
  # transport is inferred from the endpoint, so there is no `type` to set. The
  # global file is `~/.cursor/mcp.json` — shared by the CLI and the editor.
  defp install_cursor(sse_url, token) do
    merge_config(
      "cursor-agent",
      "Cursor CLI",
      Path.expand("~/.cursor/mcp.json"),
      &Codrift.JSONC.decode!/1,
      %{},
      "mcpServers",
      %{"url" => sse_url, "headers" => %{"X-Codrift-Token" => token}}
    )
  end

  defp install_codex(sse_url) do
    case System.find_executable("codex") do
      nil ->
        :skip

      _bin ->
        IO.puts("""
        Codex CLI: `codex mcp add --url` only speaks streamable HTTP, and the
          Codrift server implements the HTTP+SSE transport (MCP 2024-11-05).
          Not registering a server Codex cannot reach; the endpoint is

              #{sse_url}
        """)

        :ok
    end
  end

  defp install_copilot(sse_url) do
    case System.find_executable("gh") do
      nil ->
        :skip

      _bin ->
        IO.puts("""
        GitHub Copilot (gh): no MCP config file support.
          Point it at the SSE endpoint manually:

              #{sse_url}
        """)

        :ok
    end
  end

  # ── Config file merging ──────────────────────────────────────────────────────

  defp merge_config(executable, label, path, decode, empty, servers_key, entry) do
    case System.find_executable(executable) do
      nil ->
        :skip

      _bin ->
        IO.puts("#{label}: updating #{short(path)}...")
        merge_into(path, decode, empty, servers_key, entry)
    end
  end

  @doc false
  @spec merge_into(Path.t(), (binary() -> term()), map(), String.t(), map()) :: :ok | :error
  def merge_into(path, decode, empty, servers_key, entry) do
    with {:ok, current} <- read_config(path, decode, empty),
         updated = put_server(current, servers_key, entry),
         :ok <- backup(path),
         :ok <- write_json(path, updated) do
      IO.puts("  ✓ Added #{@server_name} to #{servers_key}")
      :ok
    else
      {:error, reason} ->
        IO.puts("  ✗ #{reason}")
        :error
    end
  end

  defp read_config(path, decode, empty) do
    case File.read(path) do
      {:ok, content} ->
        warn_if_commented(path, content)

        try do
          {:ok, decode.(content)}
        rescue
          e ->
            {:error, "#{short(path)} is not valid JSON (#{Exception.message(e)}); left untouched"}
        end

      {:error, :enoent} ->
        {:ok, empty}

      {:error, reason} ->
        {:error, "could not read #{short(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp put_server(current, servers_key, entry) when is_map(current) do
    Map.update(current, servers_key, %{@server_name => entry}, fn
      servers when is_map(servers) -> Map.put(servers, @server_name, entry)
      _ -> %{@server_name => entry}
    end)
  end

  # Comments cannot survive a decode/encode round-trip, so say so rather than
  # silently deleting a user's annotations.
  defp warn_if_commented(path, content) do
    if Codrift.JSONC.strip_comments(content) != content do
      IO.puts("  ! comments in #{Path.basename(path)} are dropped on rewrite (backup: .bak)")
    end
  end

  defp backup(path) do
    if File.exists?(path) do
      case File.copy(path, path <> ".bak") do
        {:ok, _bytes} ->
          :ok

        {:error, reason} ->
          {:error, "could not back up #{short(path)}: #{:file.format_error(reason)}"}
      end
    else
      :ok
    end
  end

  defp write_json(path, data) do
    path |> Path.dirname() |> File.mkdir_p!()
    body = data |> :json.format() |> IO.iodata_to_binary()

    case File.write(path, body) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "could not write #{short(path)}: #{:file.format_error(reason)}"}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # `--port=` wins; otherwise take the port the server is actually configured
  # to bind. The release runs this through `eval`, which loads the release
  # config but no Mix project, so this is the only source of truth there.
  @doc false
  @spec resolve_port([String.t()]) :: pos_integer()
  def resolve_port(args) do
    case Enum.find(args, &String.starts_with?(&1, "--port=")) do
      nil -> configured_port()
      flag -> flag |> String.slice(7..-1//1) |> String.to_integer()
    end
  end

  defp short(path), do: Codrift.Paths.compact(path)

  defp configured_port do
    case Application.get_env(:codrift, :bandit_opts, [])[:port] do
      port when is_integer(port) and port > 0 -> port
      _ -> @default_port
    end
  end
end

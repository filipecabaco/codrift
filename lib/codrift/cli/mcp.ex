defmodule Codrift.CLI.MCP do
  @moduledoc """
  CLI implementation for MCP server registration.

  The Mix task (`mix codrift.mcp.install`) delegates to this module, and the
  release command (`codrift mcp install`) calls it via `eval`.

  ## Usage

      codrift mcp install [--port=43117]

  Registers the Codrift SSE endpoint with every detected AI CLI:

    - **Claude Code** — `claude mcp add --scope user --transport sse`
    - **Gemini CLI** — merges `mcpServers` into `~/.gemini/settings.json`
    - **Opencode** — merges `mcp` block into `~/.config/opencode/opencode.jsonc`
    - **Codex** — prints manual instructions (it only speaks streamable HTTP)
    - **Copilot** — prints manual instructions (gh copilot has no MCP config)

  Editing someone else's config file is destructive, so every write pretty-
  prints (a minified one-liner is not a config a human can keep maintaining),
  leaves a `.bak` sibling, and warns when a JSONC round-trip drops comments.
  """

  @server_name "codrift"
  @default_port 43_117

  @doc "Dispatches MCP CLI subcommands from argv."
  @spec run([String.t()]) :: :ok
  def run(["install" | args]), do: install(args)

  def run(_) do
    IO.puts("""
    Usage:
      codrift mcp install [--port=<port>]

    Registers the Codrift MCP server with all detected AI CLIs.
    """)
  end

  # ── Subcommands ──────────────────────────────────────────────────────────────

  defp install(args) do
    port = resolve_port(args)
    sse_url = "http://localhost:#{port}/mcp/sse"
    # State-changing MCP calls must authenticate to the local server (see
    # Codrift.Plugs.LocalGuard); registrations embed the stable local token.
    token = Codrift.AuthToken.fetch()

    results = [
      install_claude(sse_url, token),
      install_gemini(sse_url, token),
      install_opencode(sse_url, token),
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
  end

  # ── Per-client installers ────────────────────────────────────────────────────

  defp install_claude(sse_url, token) do
    case System.find_executable("claude") do
      nil ->
        :skip

      _bin ->
        IO.puts("Claude Code: registering via `claude mcp add`...")

        # `claude mcp add` refuses to overwrite an existing name, so a second
        # `codrift mcp install` would otherwise always fail. Scope is `user`
        # because the default (`local`) binds the server to the directory the
        # installer happened to run in.
        System.cmd("claude", ["mcp", "remove", @server_name, "--scope", "user"],
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

        case System.cmd("claude", args, stderr_to_stdout: true) do
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

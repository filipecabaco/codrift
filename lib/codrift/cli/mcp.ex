defmodule Codrift.CLI.MCP do
  @moduledoc """
  CLI implementation for MCP server registration.

  The Mix task (`mix codrift.mcp.install`) delegates to this module, and the
  release command (`codrift mcp install`) calls it via `eval`.

  ## Usage

      codrift mcp install [--port=7437]

  Registers the Codrift SSE endpoint with every detected AI CLI:

    - **Claude Code** — `claude mcp add --transport sse`
    - **Gemini CLI** — merges `mcpServers` into `~/.gemini/settings.json`
    - **Opencode** — merges `mcp` block into `~/.config/opencode/opencode.jsonc`
    - **Codex** — prints manual instructions (no MCP config file support yet)
    - **Copilot** — prints manual instructions (gh copilot has no MCP config)
  """

  @server_name "codrift"
  @default_port 7_437

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
    port = parse_port(args)
    sse_url = "http://localhost:#{port}/mcp/sse"
    # State-changing MCP calls must authenticate to the local server (see
    # Codrift.Plugs.LocalGuard); registrations embed the stable local token.
    token = Codrift.AuthToken.fetch()

    results = [
      install_claude(sse_url, token),
      install_gemini(port, sse_url, token),
      install_opencode(port, sse_url, token),
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

        case System.cmd(
               "claude",
               [
                 "mcp",
                 "add",
                 @server_name,
                 "--transport",
                 "sse",
                 sse_url,
                 "--header",
                 "X-Codrift-Token: #{token}"
               ],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            IO.puts("  ✓ #{String.trim(output)}")
            :ok

          {output, code} ->
            IO.puts("  ✗ claude mcp add exited #{code}: #{String.trim(output)}")
            IO.puts("    Manual: claude mcp add #{@server_name} --transport sse #{sse_url}")
            :error
        end
    end
  end

  defp install_gemini(_port, sse_url, token) do
    case System.find_executable("gemini") do
      nil ->
        :skip

      _bin ->
        path = Path.expand("~/.gemini/settings.json")
        IO.puts("Gemini CLI: updating #{path}...")

        current =
          case File.read(path) do
            {:ok, content} -> JSON.decode!(content)
            {:error, _} -> %{}
          end

        mcp_entry = %{
          "type" => "sse",
          "url" => sse_url,
          "headers" => %{"X-Codrift-Token" => token}
        }

        updated =
          Map.update(current, "mcpServers", %{@server_name => mcp_entry}, fn servers ->
            Map.put(servers, @server_name, mcp_entry)
          end)

        path |> Path.dirname() |> File.mkdir_p!()

        case File.write(path, JSON.encode!(updated)) do
          :ok ->
            IO.puts("  ✓ Added #{@server_name} to mcpServers")
            :ok

          {:error, reason} ->
            IO.puts("  ✗ Could not write #{path}: #{reason}")
            :error
        end
    end
  end

  defp install_opencode(_port, sse_url, token) do
    case System.find_executable("opencode") do
      nil ->
        :skip

      _bin ->
        path = Path.expand("~/.config/opencode/opencode.jsonc")
        IO.puts("Opencode: updating #{path}...")

        current =
          case File.read(path) do
            {:ok, content} ->
              content |> strip_jsonc_comments() |> JSON.decode!()

            {:error, _} ->
              %{"$schema" => "https://opencode.ai/config.json"}
          end

        mcp_entry = %{
          "type" => "sse",
          "url" => sse_url,
          "headers" => %{"X-Codrift-Token" => token}
        }

        updated =
          Map.update(current, "mcp", %{@server_name => mcp_entry}, fn servers ->
            Map.put(servers, @server_name, mcp_entry)
          end)

        path |> Path.dirname() |> File.mkdir_p!()

        case File.write(path, JSON.encode!(updated)) do
          :ok ->
            IO.puts("  ✓ Added #{@server_name} to mcp servers")
            :ok

          {:error, reason} ->
            IO.puts("  ✗ Could not write #{path}: #{reason}")
            :error
        end
    end
  end

  defp install_codex(sse_url) do
    case System.find_executable("codex") do
      nil ->
        :skip

      _bin ->
        IO.puts("""
        Codex CLI: no config-file MCP support detected.
          Point it at the SSE endpoint manually when prompted:

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

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp parse_port(args) do
    case Enum.find(args, &String.starts_with?(&1, "--port=")) do
      nil -> @default_port
      flag -> flag |> String.slice(7..-1//1) |> String.to_integer()
    end
  end

  # Strip `//` line comments so JSONC files can be parsed as plain JSON.
  defp strip_jsonc_comments(content) do
    content
    |> String.split("\n")
    |> Enum.map_join("\n", &Regex.replace(~r|//.*$|, &1, ""))
  end
end

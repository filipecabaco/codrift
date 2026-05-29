defmodule Codrift.CLI.Integration do
  @moduledoc """
  CLI implementation for external integration commands.

  Reads and writes files directly — no GenServer required — so it works in the
  release `eval` context and when the TUI is not running.

  All output is JSON to stdout; errors go to stderr with a non-zero exit.

  ## Auth flows

  - PKCE (github, linear, gitlab, jira): delegates to the running web server
    at localhost:7437, which holds the StateStore. The TUI must be running.
  - Guided token (notion): fully local — prompts the user to paste a token
    created in Notion's web UI. No server needed.
  - API key env var: fallback for CI or headless environments.
  """

  alias Codrift.Initiative
  alias Codrift.Initiative.Store
  alias Codrift.Integration
  alias Codrift.OAuth
  alias Codrift.OAuth.Config, as: OAuthConfig

  @server_url "http://localhost:7437"
  @initiatives_file "~/.config/codrift/initiatives.json"

  @spec run([String.t()]) :: :ok

  def run(["services" | _]) do
    services =
      Enum.map(Integration.adapters(), fn mod ->
        name = mod.name()

        %{
          name: name,
          connected: OAuth.connected?(name),
          auth: service_auth_type(name)
        }
      end)

    print_json(services)
  end

  # Auth — dispatch on flow type
  def run(["auth", service | _]) do
    case OAuthConfig.get(service) do
      {:ok, %{flow: :pkce_browser}} ->
        pkce_auth_via_server(service)

      {:ok, %{flow: :guided_token, instructions: instructions}} ->
        guided_token_prompt(service, instructions)

      {:error, _} ->
        fail("Unknown service or no auth configured for: #{service}")
    end
  end

  def run(["tokens" | _]) do
    print_json(OAuth.list_tokens())
  end

  def run(["revoke", service | _]) do
    OAuth.revoke_token(service)
    print_json(%{revoked: service})
  end

  def run(["list", service | rest]) do
    filter = Enum.find(rest, &(!String.starts_with?(&1, "--")))
    opts = if filter, do: [filter: filter], else: []

    with {:ok, adapter} <- Integration.adapter_for(service),
         {:ok, items} <- adapter.list_items(opts) do
      print_json(Enum.map(items, &item_to_map/1))
    else
      {:error, reason} -> fail(reason)
    end
  end

  def run(["import", service, item_id | rest]) do
    opts = parse_opts(rest)

    with {:ok, adapter} <- Integration.adapter_for(service),
         {:ok, item} <- adapter.get_item(item_id, opts) do
      initiative = Initiative.new(item.title)
      ctx = context_path(initiative.id)
      File.mkdir_p!(ctx)
      Store.write_initiative_md_for_cli(ctx, initiative)
      persist(initiative)

      :ok =
        Integration.write_integration_files(
          initiative.id,
          service,
          item_id,
          adapter.to_initiative_context(item)
        )

      final =
        if dir = opts[:dir] do
          updated = %{initiative | dirs: [Path.expand(dir)]}
          persist(updated)
          updated
        else
          initiative
        end

      print_json(Initiative.to_map(final))
    else
      {:error, reason} -> fail(reason)
    end
  end

  def run(["sync", initiative_id | _]) do
    case Integration.sync_initiative(initiative_id) do
      {:ok, result} -> print_json(result)
      {:error, reason} -> fail(reason)
    end
  end

  def run(_) do
    IO.puts("""
    Usage:
      codrift integration services
      codrift integration auth   <service>
      codrift integration tokens
      codrift integration revoke <service>
      codrift integration list   <service> [filter]
      codrift integration import <service> <item_id> [--dir=<path>]
      codrift integration sync   <initiative_id>

    Services: #{Integration.valid_services() |> Enum.join(", ")}

    Auth flows:
      PKCE browser  (github, github_projects, linear, linear_projects, gitlab, jira)
                    — requires the TUI to be running (`codrift tui`)
      Guided token  (notion) — no server needed, just follow the prompts
      API key only  (shortcut) — set SHORTCUT_TOKEN env var
    """)
  end

  # ── Auth helpers ──────────────────────────────────────────────────────────────

  # PKCE auth delegates to the running server: the PKCE StateStore
  # lives in the server process, not in this eval process.
  defp pkce_auth_via_server(service) do
    case server_get("#{@server_url}/oauth/start/#{service}") do
      {:ok, %{"auth_url" => auth_url}} ->
        IO.puts("\nOpen this URL in your browser to authorize #{service}:\n")
        IO.puts("  #{auth_url}\n")
        IO.puts("The Codrift web server will capture the callback and store the token.")
        IO.puts("Run `codrift integration tokens` to confirm.\n")

      {:error, :server_unavailable} ->
        fail(
          "The Codrift TUI must be running to authorize #{service}.\n" <>
            "Start it with `codrift tui`, then run this command again in a second terminal."
        )

      {:error, reason} ->
        fail(reason)
    end
  end

  # Guided token: fully local, no server needed.
  defp guided_token_prompt(service, instructions) do
    IO.puts("\n#{String.trim(instructions)}\n")
    token = IO.gets("Token: ") |> String.trim()

    if token == "" do
      fail("No token entered.")
    end

    case OAuth.save_guided_token(service, token) do
      :ok ->
        IO.puts("\nConnected to #{service}. Run `codrift integration list #{service}` to test.\n")

      {:error, reason} ->
        fail(reason)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp service_auth_type(name) do
    case OAuthConfig.get(name) do
      {:ok, %{flow: :pkce_browser}} -> "pkce_browser"
      {:ok, %{flow: :guided_token}} -> "guided_token"
      _ -> "api_key_only"
    end
  end

  defp item_to_map(%Integration.Item{} = item) do
    %{
      id: item.id,
      title: item.title,
      url: item.url,
      status: item.status,
      assignee: item.assignee,
      labels: item.labels || []
    }
  end

  defp parse_opts(args) do
    Enum.reduce(args, [], fn arg, acc ->
      if String.starts_with?(arg, "--dir=") do
        Keyword.put(acc, :dir, String.slice(arg, 6..-1//1))
      else
        acc
      end
    end)
  end

  defp persist(initiative) do
    path = Path.expand(@initiatives_file)
    data = Map.put(load_raw(), initiative.id, Initiative.to_map(initiative))
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, JSON.encode!(%{"initiatives" => data}))
  end

  defp load_raw do
    path = Path.expand(@initiatives_file)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, %{"initiatives" => raw}} <- JSON.decode(content) do
      raw
    else
      _ -> %{}
    end
  end

  defp context_path(id), do: Path.expand("~/.codrift/initiatives/#{id}")

  defp server_get(url) do
    Application.ensure_all_started(:inets)

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [{:timeout, 3_000}],
           [{:body_format, :binary}]
         ) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, JSON.decode!(body)}
      {:ok, {{_, status, _}, _, body}} -> {:error, "HTTP #{status}: #{body}"}
      {:error, {:failed_connect, _}} -> {:error, :server_unavailable}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp print_json(data), do: IO.puts(JSON.encode!(data))

  @spec fail(term()) :: no_return()
  defp fail(reason) do
    IO.puts(:stderr, JSON.encode!(%{error: to_string(reason)}))
    System.halt(1)
  end
end

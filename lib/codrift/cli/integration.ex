defmodule Codrift.CLI.Integration do
  @moduledoc """
  CLI implementation for external integration commands.

  Reads and writes files directly — no GenServer required — so it works in the
  release `eval` context and when the TUI is not running.

  All output is JSON to stdout; errors go to stderr with a non-zero exit.

  ## Usage

      codrift integration services
      codrift integration list   <service> [filter]
      codrift integration import <service> <item_id> [--dir=<path>]
      codrift integration sync   <initiative_id>

  ## Services

      github           GitHub Issues (GITHUB_TOKEN, GITHUB_REPO)
      github_projects  GitHub Projects v2 (GITHUB_TOKEN)
      linear           Linear Issues (LINEAR_API_KEY)
      linear_projects  Linear Projects (LINEAR_API_KEY)
      gitlab           GitLab Issues (GITLAB_TOKEN, GITLAB_PROJECT)
      jira             Jira Cloud Issues (JIRA_HOST, JIRA_EMAIL, JIRA_TOKEN)
      notion           Notion Pages/Databases (NOTION_API_KEY)
      shortcut         Shortcut Stories (SHORTCUT_TOKEN)
      asana            Asana Tasks (ASANA_ACCESS_TOKEN)
  """

  alias Codrift.Initiative
  alias Codrift.Initiative.Store
  alias Codrift.Integration
  alias Codrift.OAuth

  @server_url "http://localhost:7437"
  @initiatives_file "~/.config/codrift/initiatives.json"

  @spec run([String.t()]) :: :ok
  def run(["services" | _]) do
    services =
      Enum.map(Integration.adapters(), fn mod ->
        %{
          name: mod.name(),
          connected: OAuth.connected?(mod.name()),
          oauth_supported: mod.name() in Codrift.OAuth.Config.supported_services()
        }
      end)

    print_json(services)
  end

  def run(["auth", service | _]) do
    url = "#{@server_url}/oauth/start/#{service}"

    case oauth_request(url) do
      {:ok, %{"auth_url" => auth_url}} ->
        IO.puts("Open the following URL in your browser to authorize #{service}:\n")
        IO.puts("  #{auth_url}\n")
        IO.puts("The Codrift web server will handle the callback automatically.")
        IO.puts("Run `codrift integration tokens` to confirm the connection.")

      {:error, :server_unavailable} ->
        fail(
          "Codrift web server is not running. Start the TUI first (`codrift tui`) " <>
            "so the OAuth callback can be received."
        )

      {:error, reason} ->
        fail(reason)
    end
  end

  def run(["tokens" | _]) do
    tokens = OAuth.list_tokens()
    print_json(tokens)
  end

  def run(["revoke", service | _]) do
    OAuth.revoke_token(service)
    print_json(%{revoked: service})
  end

  def run(["list", service | rest]) do
    filter = Enum.find(rest, fn arg -> !String.starts_with?(arg, "--") end)
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
      write_meta!(initiative.id, service, item_id)
      write_context!(initiative.id, adapter.to_initiative_context(item))

      if dir = opts[:dir] do
        expanded = Path.expand(dir)
        updated = %{initiative | dirs: [expanded]}
        persist(updated)
        print_json(Initiative.to_map(updated))
      else
        print_json(Initiative.to_map(initiative))
      end
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
    services = Integration.valid_services() |> Enum.join(", ")

    IO.puts("""
    Usage:
      codrift integration services
      codrift integration auth   <service>
      codrift integration tokens
      codrift integration revoke <service>
      codrift integration list   <service> [filter]
      codrift integration import <service> <item_id> [--dir=<path>]
      codrift integration sync   <initiative_id>

    Services: #{services}

    OAuth2 (recommended): run `codrift integration auth <service>` while the TUI is
    running — it will open a browser-based authorization flow and store the token.

    API key fallback: set service-specific env vars (run `codrift integration services`
    to see which ones are connected).
    """)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

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

  # Directly writes to initiatives.json without going through the GenServer.
  defp persist(initiative) do
    path = Path.expand(@initiatives_file)
    existing = load_raw()
    data = Map.put(existing, initiative.id, Initiative.to_map(initiative))
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

  defp write_meta!(initiative_id, service, item_id) do
    path = Integration.meta_path(initiative_id)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, JSON.encode!(%{service: service, item_id: item_id}))
  end

  defp write_context!(initiative_id, content) do
    path = Integration.context_path(initiative_id)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
  end

  defp context_path(id), do: Path.expand("~/.codrift/initiatives/#{id}")

  defp oauth_request(url) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    ssl_opts = [
      verify: :verify_none
    ]

    case :httpc.request(:get, {String.to_charlist(url), []}, [ssl: ssl_opts, timeout: 3_000], [
           body_format: :binary
         ]) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, JSON.decode!(body)}

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, "server returned HTTP #{status}: #{body}"}

      {:error, {:failed_connect, _}} ->
        {:error, :server_unavailable}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp print_json(data), do: IO.puts(JSON.encode!(data))

  @spec fail(term()) :: no_return()
  defp fail(reason) do
    IO.puts(:stderr, JSON.encode!(%{error: to_string(reason)}))
    System.halt(1)
  end
end

defmodule Codrift.CLI.Integration do
  @moduledoc """
  CLI implementation for external integration commands.

  Reads and writes files directly — no GenServer required — so it works in the
  release `eval` context and when the desktop app is not running.

  All output is JSON to stdout; errors go to stderr with a non-zero exit.

  ## Auth flows

  - PKCE (linear, gitlab): delegates to the running web server at localhost:43117,
    which holds the StateStore. The desktop app must be running.
  - Device Flow (github): authorize from the desktop app's Integrations panel.
  - API key env var: fallback for CI or headless environments.
  """

  alias Codrift.Initiative
  alias Codrift.Initiative.Store
  alias Codrift.Integration
  alias Codrift.OAuth
  alias Codrift.OAuth.Config, as: OAuthConfig
  alias Codrift.Paths

  @server_url "http://localhost:43117"

  defp initiatives_file, do: Path.join(Paths.config_dir(), "initiatives.json")

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

      {:ok, %{flow: :device_flow}} ->
        fail(
          "#{service} uses device flow — authorize it from the desktop app's Integrations panel."
        )

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

  def run(["assigned" | rest]) do
    service = Enum.find(rest, &(!String.starts_with?(&1, "--")))

    %{items: items, errors: errors} = Integration.list_assigned(initiatives: load_initiatives())

    items =
      case service do
        nil -> items
        name -> Enum.filter(items, &(&1.service == name))
      end

    print_json(%{items: Enum.map(items, &assigned_to_map/1), errors: errors})
  end

  def run(["import", service, item_id | rest]) do
    opts = parse_opts(rest)

    case Integration.find_imported(service, item_id, load_initiatives()) do
      {:ok, existing} ->
        print_json(Map.put(Initiative.to_map(existing), "existing", true))

      :error ->
        do_import(service, item_id, opts)
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
      codrift integration list     <service> [filter]
      codrift integration assigned [service]
      codrift integration import   <service> <item_id> [--dir=<path>]
      codrift integration sync   <initiative_id>

    Services: #{Integration.valid_services() |> Enum.join(", ")}

    Auth flows:
      PKCE browser  (linear, linear_projects, gitlab)
                    — requires the Codrift desktop app to be running
      Device flow   (github, github_projects) — authorize from the desktop app
    """)
  end

  defp do_import(service, item_id, opts) do
    with {:ok, adapter} <- Integration.adapter_for(service),
         {:ok, item} <- adapter.get_item(item_id, opts) do
      dirs = if dir = opts[:dir], do: [Path.expand(dir)], else: []

      initiative = %{
        Initiative.new(item.title, dirs)
        | integration: %{service: service, item_id: item_id},
          status: Integration.map_item_status(item.status)
      }

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

      print_json(Map.put(Initiative.to_map(initiative), "existing", false))
    else
      {:error, reason} -> fail(reason)
    end
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
          "The Codrift desktop app must be running to authorize #{service}.\n" <>
            "Launch the app, then run this command again in a terminal."
        )

      {:error, reason} ->
        fail(reason)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp service_auth_type(name) do
    case OAuthConfig.get(name) do
      {:ok, %{flow: :pkce_browser}} -> "pkce_browser"
      {:ok, %{flow: :device_flow}} -> "device_flow"
      _ -> "api_key_only"
    end
  end

  defp assigned_to_map(%{service: service, item: item, initiative_id: initiative_id}) do
    item
    |> item_to_map()
    |> Map.merge(%{
      service: service,
      initiative_id: initiative_id,
      imported: not is_nil(initiative_id)
    })
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
    data = Map.put(load_raw(), initiative.id, Initiative.to_map(initiative))
    Codrift.Files.write_atomic!(initiatives_file(), JSON.encode!(%{"initiatives" => data}))
  end

  defp load_initiatives do
    load_raw()
    |> Map.values()
    |> Enum.flat_map(fn data ->
      case Initiative.from_map(data) do
        {:ok, initiative} -> [initiative]
        _ -> []
      end
    end)
  end

  defp load_raw do
    path = initiatives_file()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, %{"initiatives" => raw}} <- JSON.decode(content) do
      raw
    else
      _ -> %{}
    end
  end

  defp context_path(id), do: Paths.initiative_dir(id)

  defp server_get(url) do
    case Req.get(url, receive_timeout: 3_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{inspect(body)}"}
      {:error, %{reason: :econnrefused}} -> {:error, :server_unavailable}
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

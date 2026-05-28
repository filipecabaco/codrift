defmodule Codrift.Integration do
  @moduledoc """
  External integration layer for seeding Codrift initiatives from project
  management services (GitHub, Linear, GitLab, Jira, Notion, Shortcut, Asana).

  ## Design principles

  - Read-first: primary flow is pulling context *into* Codrift, not pushing back out.
  - One adapter per service: each integration implements the `Codrift.Integration` behaviour.
  - Credentials in env: API tokens are read from environment variables; nothing stored in DB.
  - Context folder injection: pulled content is written into
    `~/.codrift/initiatives/{id}/integration.md` and automatically picked up by agents
    via the `--add-dir` context mechanism.

  ## Usage

      # List adapters
      Codrift.Integration.valid_services()
      # => ["github", "github_projects", "linear", ...]

      # Import an item as a new initiative
      {:ok, initiative} = Codrift.Integration.import_item("github", "owner/repo#42")

      # Re-sync context after the remote item changes
      {:ok, _} = Codrift.Integration.sync_initiative(initiative.id)
  """

  defmodule Item do
    @moduledoc "A single item pulled from an external project management service."

    @enforce_keys [:id, :title, :url]
    defstruct [:id, :title, :description, :url, :labels, :status, :assignee, :linked_prs]

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t(),
            description: String.t() | nil,
            url: String.t(),
            labels: [String.t()],
            status: String.t() | nil,
            assignee: String.t() | nil,
            linked_prs: [String.t()]
          }
  end

  @callback name() :: String.t()
  @callback list_items(opts :: keyword()) :: {:ok, [Item.t()]} | {:error, term()}
  @callback get_item(id :: String.t(), opts :: keyword()) :: {:ok, Item.t()} | {:error, term()}
  @callback to_initiative_context(Item.t()) :: String.t()

  @adapters [
    Codrift.Integration.Adapters.GitHub,
    Codrift.Integration.Adapters.GitHubProjects,
    Codrift.Integration.Adapters.Linear,
    Codrift.Integration.Adapters.LinearProjects,
    Codrift.Integration.Adapters.GitLab,
    Codrift.Integration.Adapters.Jira,
    Codrift.Integration.Adapters.Notion,
    Codrift.Integration.Adapters.Shortcut,
    Codrift.Integration.Adapters.Asana
  ]

  @doc "Returns all registered integration adapter modules."
  @spec adapters() :: [module()]
  def adapters, do: @adapters

  @doc "Returns the list of valid service name strings."
  @spec valid_services() :: [String.t()]
  def valid_services, do: Enum.map(@adapters, & &1.name())

  @doc "Returns `{:ok, adapter_module}` for a named service, or `{:error, reason}`."
  @spec adapter_for(String.t()) :: {:ok, module()} | {:error, String.t()}
  def adapter_for(name) do
    case Enum.find(@adapters, fn mod -> mod.name() == name end) do
      nil ->
        {:error,
         "unknown integration: #{name}. Valid services: #{Enum.join(valid_services(), ", ")}"}

      mod ->
        {:ok, mod}
    end
  end

  @doc """
  Imports an item from an external service into a new Codrift initiative.

  Steps:
  1. Fetches the item from the service.
  2. Creates an initiative named after the item.
  3. Writes `integration.json` (metadata for future sync).
  4. Writes `integration.md` (human/agent-readable context).
  5. Optionally adds a working directory to the initiative.

  ## Options
  - `:dir` — working directory path to add to the initiative
  """
  @spec import_item(String.t(), String.t(), keyword()) ::
          {:ok, Codrift.Initiative.t()} | {:error, term()}
  def import_item(service, item_id, opts \\ []) do
    with {:ok, adapter} <- adapter_for(service),
         {:ok, item} <- adapter.get_item(item_id, opts),
         {:ok, initiative} <- Codrift.Initiative.Store.create(item.title, []),
         :ok <- write_meta(initiative.id, service, item_id),
         :ok <- write_context(initiative.id, adapter.to_initiative_context(item)) do
      case Keyword.get(opts, :dir) do
        nil -> :ok
        dir -> Codrift.Initiative.Store.add_dir(initiative.id, Path.expand(dir))
      end

      {:ok, initiative}
    end
  end

  @doc """
  Re-fetches the external item and overwrites `integration.md` for an initiative.

  Returns `{:error, reason}` when the initiative was not created from an integration.
  """
  @spec sync_initiative(String.t()) ::
          {:ok, %{synced: true, service: String.t(), item_id: String.t()}}
          | {:error, term()}
  def sync_initiative(initiative_id) do
    with {:ok, meta} <- read_meta(initiative_id),
         {:ok, adapter} <- adapter_for(meta["service"]),
         {:ok, item} <- adapter.get_item(meta["item_id"], []),
         :ok <- write_context(initiative_id, adapter.to_initiative_context(item)) do
      {:ok, %{synced: true, service: meta["service"], item_id: meta["item_id"]}}
    end
  end

  @doc "Returns the path to the integration metadata JSON file for an initiative."
  @spec meta_path(String.t()) :: String.t()
  def meta_path(initiative_id),
    do: Path.expand("~/.codrift/initiatives/#{initiative_id}/integration.json")

  @doc "Returns the path to the integration context Markdown file for an initiative."
  @spec context_path(String.t()) :: String.t()
  def context_path(initiative_id),
    do: Path.expand("~/.codrift/initiatives/#{initiative_id}/integration.md")

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp write_meta(initiative_id, service, item_id) do
    path = meta_path(initiative_id)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write(path, JSON.encode!(%{service: service, item_id: item_id}))
  end

  defp read_meta(initiative_id) do
    path = meta_path(initiative_id)

    case File.read(path) do
      {:ok, content} -> {:ok, JSON.decode!(content)}
      {:error, :enoent} -> {:error, "initiative #{initiative_id} was not imported from a service"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp write_context(initiative_id, content) do
    path = context_path(initiative_id)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write(path, content)
  end
end

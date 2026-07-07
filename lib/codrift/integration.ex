defmodule Codrift.Integration do
  @moduledoc """
  External integration layer for seeding Codrift initiatives from project
  management services (GitHub, Linear, GitLab).

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
    defstruct [
      :id,
      :title,
      :description,
      :url,
      :labels,
      :status,
      :assignee,
      :linked_prs,
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t(),
            description: String.t() | nil,
            url: String.t(),
            labels: [String.t()],
            status: String.t() | nil,
            assignee: String.t() | nil,
            linked_prs: [String.t()],
            metadata: map()
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
    Codrift.Integration.Adapters.GitLab
  ]

  alias Codrift.Initiative.Store

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
         {:ok, initiative} <- Store.create(item.title, []),
         :ok <- write_meta(initiative.id, service, item_id),
         :ok <- write_context(initiative.id, adapter.to_initiative_context(item)),
         :ok <- maybe_add_dir(initiative.id, opts) do
      {:ok, initiative}
    end
  end

  @doc "Writes integration.json and integration.md for a pre-existing initiative (file I/O only, no GenServer)."
  @spec write_integration_files(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def write_integration_files(initiative_id, service, item_id, context) do
    with :ok <- write_meta(initiative_id, service, item_id) do
      write_context(initiative_id, context)
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

  @doc """
  Maps a service-specific status string to a Codrift initiative status atom.

  Covers the most common status names across GitHub, Linear, GitLab, and
  GitHub Projects. Unknown values default to `:ongoing`.
  """
  @spec map_item_status(String.t() | nil) :: Codrift.Initiative.status()
  def map_item_status(status) do
    cond do
      status in ~w[done closed completed resolved merged fixed] -> :done
      status in ~w[cancelled canceled archived wontfix won't_fix dismissed] -> :archived
      status in ~w[planning backlog todo unstarted triage icebox] -> :planning
      true -> :ongoing
    end
  end

  @doc "Returns the path to the integration metadata JSON file for an initiative."
  @spec meta_path(String.t()) :: String.t()
  def meta_path(initiative_id),
    do: Path.join(Codrift.Paths.initiative_dir(initiative_id), "integration.json")

  @doc "Returns the path to the integration context Markdown file for an initiative."
  @spec context_path(String.t()) :: String.t()
  def context_path(initiative_id),
    do: Path.join(Codrift.Paths.initiative_dir(initiative_id), "integration.md")

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp maybe_add_dir(_id, []), do: :ok

  defp maybe_add_dir(id, opts) do
    case Keyword.get(opts, :dir) do
      nil -> :ok
      dir -> Store.add_dir(id, Path.expand(dir))
    end
  end

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

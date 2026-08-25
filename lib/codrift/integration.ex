defmodule Codrift.Integration do
  @moduledoc """
  External integration layer for seeding Codrift initiatives from project
  management services (GitHub, Linear, GitLab).

  ## Design principles

  - Read-first: primary flow is pulling context *into* Codrift, not pushing back out.
  - One adapter per service: each integration implements the `Codrift.Integration` behaviour.
  - Credentials in env: API tokens are read from environment variables; nothing stored in DB.
  - Context folder injection: pulled content is written into
    the `source` block of `~/.codrift/initiatives/{id}/initiative.md` and automatically
    picked up by agents
    via the `--add-dir` context mechanism.

  ## Usage

      # List adapters
      Codrift.Integration.valid_services()
      # => ["github", "github_projects", "linear", ...]

      # Everything assigned to you across every connected service
      %{items: items} = Codrift.Integration.list_assigned()

      # Import an item as a new initiative
      {:ok, :imported, initiative} = Codrift.Integration.import_item("github", "owner/repo#42")

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

    @doc """
    Normalises a field the API left empty to `nil`.

    Trackers return `""` as readily as `null` for an unfilled description, and
    only `nil` triggers the "no description" fallbacks in `to_initiative_context/1`.
    """
    @spec presence(String.t() | nil) :: String.t() | nil
    def presence(nil), do: nil

    def presence(value) when is_binary(value) do
      if String.trim(value) == "", do: nil, else: value
    end
  end

  @callback name() :: String.t()

  @doc """
  Whether this adapter has usable credentials (OAuth token or env var).

  Checked before fanning out in `list_assigned/1` so unconfigured services are
  skipped instead of reported as failures.
  """
  @callback credentials?() :: boolean()

  @callback list_items(opts :: keyword()) :: {:ok, [Item.t()]} | {:error, term()}

  @doc """
  The authenticated user's queue: items assigned to them, plus ones they opened
  themselves.

  Each item carries why it is in the queue under `metadata.relation` — build the
  list with `merge_sources/1` so the tag is set consistently.

  Return `{:error, :not_configured}` when the adapter needs scope it does not
  have (e.g. a project board without a configured project) — the aggregator
  drops those silently rather than surfacing them as errors.
  """
  @callback list_assigned(opts :: keyword()) :: {:ok, [Item.t()]} | {:error, term()}

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
  alias Codrift.Integration.Error

  @doc "Returns all registered integration adapter modules."
  @spec adapters() :: [module()]
  def adapters, do: @adapters

  @doc "Returns the list of valid service name strings."
  @spec valid_services() :: [String.t()]
  def valid_services, do: Enum.map(@adapters, & &1.name())

  @doc """
  Returns `{:ok, adapter_module}` for a named service, or `{:error, reason}`.

  Pass `adapters: [...]` to resolve against a different adapter list.
  """
  @spec adapter_for(String.t(), keyword()) :: {:ok, module()} | {:error, String.t()}
  def adapter_for(name, opts \\ []) do
    adapters = Keyword.get(opts, :adapters, @adapters)

    case Enum.find(adapters, fn mod -> mod.name() == name end) do
      nil ->
        known = Enum.map_join(adapters, ", ", & &1.name())
        {:error, "unknown integration: #{name}. Valid services: #{known}"}

      mod ->
        {:ok, mod}
    end
  end

  @typedoc "An item in the user's queue, with the initiative it was already imported into (`nil` when new)."
  @type assigned :: %{
          service: String.t(),
          item: Item.t(),
          relation: String.t(),
          initiative_id: String.t() | nil
        }

  @default_relation "assigned"

  @doc """
  Merges the results of several per-relation queries into one tagged list.

  Takes `[{relation, {:ok, items} | {:error, reason}}]`. An item found by more
  than one query keeps the first relation it matched, so pass the strongest
  signal first. Returns an error only when every query failed — one unavailable
  source should never hide the others.
  """
  @spec merge_sources([{String.t(), {:ok, [Item.t()]} | {:error, term()}}]) ::
          {:ok, [Item.t()]} | {:error, term()}
  def merge_sources(sources) do
    case Enum.split_with(sources, &match?({_relation, {:ok, _}}, &1)) do
      {[], [{_relation, error} | _]} ->
        error

      {ok, _failed} ->
        {:ok,
         ok
         |> Enum.flat_map(fn {relation, {:ok, items}} -> tag_relation(items, relation) end)
         |> Enum.uniq_by(& &1.id)}
    end
  end

  @doc "Records why an item is in the user's queue."
  @spec tag_relation([Item.t()], String.t()) :: [Item.t()]
  def tag_relation(items, relation) do
    Enum.map(items, &%{&1 | metadata: Map.put(&1.metadata, :relation, relation)})
  end

  @doc """
  Renders a list of labels as prose for an initiative brief: `"a, b"`, or
  `"none"` when there are none.

  Lives here rather than in each adapter because the brief it feeds is what an
  agent is briefed from — four copies of this is four chances for one tracker's
  brief to say `[]` where the others say `none`.
  """
  @spec format_list([String.t()]) :: String.t()
  def format_list([]), do: "none"
  def format_list(items), do: Enum.join(items, ", ")

  @doc "Returns an item's relation to the user, defaulting to `\"assigned\"`."
  @spec relation(Item.t()) :: String.t()
  def relation(%Item{metadata: %{relation: relation}}), do: relation
  def relation(%Item{}), do: @default_relation

  @assigned_timeout_ms 15_000

  @doc """
  Fetches everything assigned to the authenticated user across every credentialed
  service, in parallel.

  Each item carries the initiative it was already imported into (`nil` when it is
  new), so callers can keep to one initiative per issue.

  Services without credentials are skipped. Services that answer
  `{:error, :not_configured}` are skipped too; every other failure lands in
  `:errors` so the UI can say which service is broken while still showing the
  rest.

  ## Options
  - `:initiatives` — initiative list used to detect already-imported items
    (defaults to `Store.list/0`; pass explicitly outside the supervision tree)
  - `:adapters` — adapter list to query (defaults to every registered adapter)
  - any other option is forwarded to the adapters
  """
  @spec list_assigned(keyword()) :: %{
          items: [assigned()],
          errors: [%{service: String.t(), reason: String.t(), kind: Error.kind()}]
        }
  def list_assigned(opts \\ []) do
    {initiatives, opts} = Keyword.pop_lazy(opts, :initiatives, fn -> Store.list() end)
    {adapters, adapter_opts} = Keyword.pop(opts, :adapters, @adapters)

    index = imported_index(initiatives)

    results =
      adapters
      |> Enum.filter(& &1.credentials?())
      |> Task.async_stream(
        fn mod -> {mod.name(), mod.list_assigned(adapter_opts)} end,
        max_concurrency: max(length(adapters), 1),
        timeout: @assigned_timeout_ms,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.to_list()

    %{items: collect_assigned(results, index), errors: collect_failures(results)}
  end

  defp collect_assigned(results, index) do
    for {:ok, {service, {:ok, items}}} <- results, item <- items do
      %{
        service: service,
        item: item,
        relation: relation(item),
        initiative_id: Map.get(index, {service, item.id})
      }
    end
    |> Enum.sort_by(&if(&1.relation == @default_relation, do: 0, else: 1))
  end

  # Each failure keeps its `:kind` so the UI can tell the two cases apart that
  # look identical as prose: a service that is down (wait) and a session that has
  # expired (reconnect, and here is the button).
  defp collect_failures(results) do
    Enum.flat_map(results, fn
      {:ok, {_service, {:error, :not_configured}}} ->
        []

      {:ok, {service, {:error, reason}}} ->
        [Error.to_map(reason, service)]

      {:exit, {mod, :timeout}} ->
        [%{service: mod.name(), reason: "timed out", kind: :network}]

      {:exit, {mod, reason}} ->
        [%{service: mod.name(), reason: inspect(reason), kind: :http}]

      _ ->
        []
    end)
  end

  @doc """
  Maps `{service, item_id}` to the initiative it was imported into.

  Initiatives created before the store recorded the link fall back to their
  `integration.json`, so older imports still de-duplicate.
  """
  @spec imported_index([Codrift.Initiative.t()]) :: %{{String.t(), String.t()} => String.t()}
  def imported_index(initiatives) do
    for initiative <- initiatives,
        ref = integration_ref(initiative),
        into: %{},
        do: {ref, initiative.id}
  end

  @doc "Returns the initiative a given external item was imported into, if any."
  @spec find_imported(String.t(), String.t(), [Codrift.Initiative.t()]) ::
          {:ok, Codrift.Initiative.t()} | :error
  def find_imported(service, item_id, initiatives) do
    case Enum.find(initiatives, &(integration_ref(&1) == {service, item_id})) do
      nil -> :error
      initiative -> {:ok, initiative}
    end
  end

  @doc """
  Imports an item from an external service into a new Codrift initiative.

  Steps:
  1. Fetches the item from the service.
  2. Creates an initiative named after the item, linked to the external item and
     with its status mapped from the remote one.
  3. Writes `integration.json` (metadata for future sync).
  4. Folds the item's context into the `source` block of `initiative.md`.
  5. Optionally adds a working directory to the initiative.

  One initiative per external item: when the item was already imported this
  returns `{:ok, :existing, initiative}` without touching the remote service.

  ## Options
  - `:dir` — working directory path to add to the initiative
  - `:store` — initiative store to use (defaults to `Codrift.Initiative.Store`)
  - `:adapters` — adapter list to resolve `service` against
  """
  @spec import_item(String.t(), String.t(), keyword()) ::
          {:ok, :imported | :existing, Codrift.Initiative.t()} | {:error, term()}
  def import_item(service, item_id, opts \\ []) do
    {store, opts} = Keyword.pop(opts, :store, Store)

    case find_imported(service, item_id, Store.list(store)) do
      {:ok, initiative} -> {:ok, :existing, initiative}
      :error -> do_import(service, item_id, opts, store)
    end
  end

  defp do_import(service, item_id, opts, store) do
    with {:ok, adapter} <- adapter_for(service, opts),
         {:ok, item} <- adapter.get_item(item_id, opts),
         {:ok, created} <- Store.create(item.title, [], store),
         ref = %{service: service, item_id: item_id, url: item.url},
         {:ok, _} <- Store.link_integration(created.id, ref, store),
         {:ok, _} <- Store.set_status(created.id, map_item_status(item.status), store),
         :ok <- write_meta(created.id, service, item_id),
         :ok <- write_context(created.id, adapter.to_initiative_context(item)),
         :ok <- maybe_add_dir(created.id, opts, store),
         {:ok, initiative} <- Store.get(created.id, store) do
      {:ok, :imported, initiative}
    end
  end

  @doc """
  Writes `integration.json` and refreshes the `source` block of `initiative.md`
  for a pre-existing initiative (file I/O only, no GenServer).
  """
  @spec write_integration_files(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def write_integration_files(initiative_id, service, item_id, context) do
    with :ok <- write_meta(initiative_id, service, item_id) do
      write_context(initiative_id, context)
    end
  end

  @doc """
  Re-fetches the external item and refreshes the `source` block of `initiative.md`.

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

  @doc """
  Returns the path of the document holding the imported context.

  Imported context lives in a managed block inside `initiative.md` so an agent
  has one document to read, not two.
  """
  @spec context_path(String.t()) :: String.t()
  def context_path(initiative_id), do: Store.initiative_md_path(initiative_id)

  @doc "Path of the pre-0.1 standalone context file, folded into `initiative.md` on write."
  @spec legacy_context_path(String.t()) :: String.t()
  def legacy_context_path(initiative_id),
    do: Path.join(Codrift.Paths.initiative_dir(initiative_id), "integration.md")

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp maybe_add_dir(id, opts, store) do
    case Keyword.get(opts, :dir) do
      nil -> :ok
      dir -> with {:ok, _} <- Store.add_dir(id, Path.expand(dir), [], store), do: :ok
    end
  end

  defp integration_ref(%{integration: %{service: service, item_id: item_id}}),
    do: {service, item_id}

  defp integration_ref(%{id: id}) do
    case read_meta(id) do
      {:ok, %{"service" => service, "item_id" => item_id}} -> {service, item_id}
      _ -> nil
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
    with :ok <- Store.put_managed_block(initiative_id, "source", content) do
      File.rm(legacy_context_path(initiative_id))
      :ok
    end
  end
end

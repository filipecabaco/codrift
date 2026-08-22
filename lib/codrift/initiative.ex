defmodule Codrift.Initiative do
  @moduledoc """
  Struct representing a named workspace that groups one or more directories.

  Multiple AI agents can run under one initiative, each scoped to its own
  directory but sharing the initiative's context.

  ## Lifecycle

  Initiatives move through four status values:

    - `:planning`  — work not yet started
    - `:ongoing`   — actively being worked on (default)
    - `:done`      — completed
    - `:archived`  — retained for reference, no active work
  """

  @status_cycle [:planning, :ongoing, :done, :archived]

  alias Codrift.Initiative.DirEntry

  defstruct [
    :id,
    :name,
    :dirs,
    :created_at,
    :status,
    integration: nil,
    worktree_default: false,
    agent: nil,
    scratch: false
  ]

  @type integration ::
          %{service: String.t(), item_id: String.t(), url: String.t() | nil} | nil
  @type status :: :planning | :ongoing | :done | :archived

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          dirs: [DirEntry.t()],
          created_at: DateTime.t(),
          status: status(),
          integration: integration(),
          worktree_default: boolean(),
          agent: String.t() | nil,
          scratch: boolean()
        }

  @doc """
  Creates a temporary (unsaved) initiative from a list of file or directory paths.

  Each path is resolved to its parent directory (or itself when it is already a
  directory).  Duplicate directories are collapsed to one entry.  The initiative
  is named `tmp-<unix-timestamp>` and has status `:planning`; it is **not**
  written to the store.
  """
  def create_temp(paths) do
    dirs =
      paths
      |> Enum.map(fn p ->
        abs = Path.expand(p)
        if File.dir?(abs), do: abs, else: Path.dirname(abs)
      end)
      |> Enum.uniq()
      |> Enum.map(&DirEntry.new/1)

    timestamp = DateTime.utc_now() |> DateTime.to_unix()

    %__MODULE__{
      id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      name: "tmp-#{timestamp}",
      dirs: dirs,
      created_at: DateTime.utc_now(),
      status: :planning
    }
  end

  @doc "Creates a new initiative with a random ID and the current UTC timestamp."
  def new(name, dirs \\ [], opts \\ []) do
    %__MODULE__{
      id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      name: name,
      dirs: Enum.map(dirs, &DirEntry.from_value/1),
      created_at: DateTime.utc_now(),
      status: :ongoing,
      scratch: Keyword.get(opts, :scratch, false)
    }
  end

  @doc """
  A name for a fresh scratchpad: where it was opened, and when.

  Scratchpads are opened without being named — that is the whole point — so the
  name has to be something the list can still be read by two days later. A bare
  clock reading is not: `scratch 09:03` and `scratch 14:21` say nothing about
  which was which. So when the scratchpad was opened against a directory, that
  directory's name leads, and the time only tells two of them apart.

  `label` is that directory name (nil when the scratchpad is folderless), and
  `taken` — the names already in use — decides the `(2)` suffix so two opened in
  the same minute in the same place stay distinguishable.
  """
  @spec scratch_name([String.t()], String.t() | nil) :: String.t()
  def scratch_name(taken \\ [], label \\ nil) do
    # Local wall-clock, not UTC: this name is read by a human two hours later,
    # and `NaiveDateTime.local_now/0` gets it from the system without needing a
    # tz database to be installed.
    at = Calendar.strftime(NaiveDateTime.local_now(), "%H:%M")
    # The separator earns its place only when there are two things to separate.
    base = if label in [nil, ""], do: "scratch #{at}", else: "scratch · #{label} #{at}"
    if base in taken, do: unique(base, taken, 2), else: base
  end

  defp unique(base, taken, n) do
    candidate = "#{base} (#{n})"
    if candidate in taken, do: unique(base, taken, n + 1), else: candidate
  end

  @doc "Returns the next status in the cycle (wraps around)."
  def next_status(current) do
    idx = Enum.find_index(@status_cycle, &(&1 == current)) || 0
    Enum.at(@status_cycle, rem(idx + 1, length(@status_cycle)))
  end

  @doc "Returns the previous status in the cycle (wraps around)."
  def prev_status(current) do
    idx = Enum.find_index(@status_cycle, &(&1 == current)) || 0
    Enum.at(@status_cycle, rem(idx - 1 + length(@status_cycle), length(@status_cycle)))
  end

  @doc "Serialises an initiative to a plain map suitable for JSON encoding."
  def to_map(%__MODULE__{} = i) do
    base = %{
      "id" => i.id,
      "name" => i.name,
      "dirs" => Enum.map(i.dirs, &DirEntry.to_map/1),
      "created_at" => DateTime.to_iso8601(i.created_at),
      "status" => Atom.to_string(i.status || :ongoing),
      "worktree_default" => i.worktree_default || false,
      "agent" => i.agent,
      "scratch" => i.scratch || false
    }

    case i.integration do
      nil ->
        base

      %{service: s, item_id: id} = ref ->
        Map.put(base, "integration", %{
          "service" => s,
          "item_id" => id,
          "url" => Map.get(ref, :url)
        })
    end
  end

  @doc """
  Deserialises an initiative from a plain map (as returned by JSON decoding).

  Returns `{:ok, %Initiative{}}` on success, or `{:error, reason}` when the
  map is malformed (e.g. an invalid ISO-8601 timestamp).
  """
  def from_map(%{"id" => id, "name" => name, "dirs" => dirs, "created_at" => ts} = data) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        status = data |> Map.get("status", "ongoing") |> String.to_existing_atom()

        integration =
          case data["integration"] do
            %{"service" => s, "item_id" => iid} = ref ->
              %{service: s, item_id: iid, url: Map.get(ref, "url")}

            _ ->
              nil
          end

        {:ok,
         %__MODULE__{
           id: id,
           name: name,
           dirs: Enum.map(dirs, &DirEntry.from_value/1),
           created_at: dt,
           status: status,
           integration: integration,
           worktree_default: Map.get(data, "worktree_default", false),
           agent: Map.get(data, "agent"),
           scratch: Map.get(data, "scratch", false)
         }}

      error ->
        error
    end
  end

  def from_map(data), do: {:error, {:invalid_initiative_map, data}}
end

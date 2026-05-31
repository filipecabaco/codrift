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

  defstruct [:id, :name, :dirs, :created_at, :status, integration: nil, worktree_default: false]

  @type integration :: %{service: String.t(), item_id: String.t()} | nil
  @type status :: :planning | :ongoing | :done | :archived

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          dirs: [DirEntry.t()],
          created_at: DateTime.t(),
          status: status(),
          integration: integration(),
          worktree_default: boolean()
        }

  @doc "Creates a new initiative with a random ID and the current UTC timestamp."
  def new(name, dirs \\ []) do
    %__MODULE__{
      id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      name: name,
      dirs: Enum.map(dirs, &DirEntry.from_value/1),
      created_at: DateTime.utc_now(),
      status: :ongoing
    }
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
      "worktree_default" => i.worktree_default || false
    }

    case i.integration do
      nil ->
        base

      %{service: s, item_id: id} ->
        Map.put(base, "integration", %{"service" => s, "item_id" => id})
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
            %{"service" => s, "item_id" => iid} -> %{service: s, item_id: iid}
            _ -> nil
          end

        {:ok,
         %__MODULE__{
           id: id,
           name: name,
           dirs: Enum.map(dirs, &DirEntry.from_value/1),
           created_at: dt,
           status: status,
           integration: integration,
           worktree_default: Map.get(data, "worktree_default", false)
         }}

      error ->
        error
    end
  end

  def from_map(data), do: {:error, {:invalid_initiative_map, data}}
end

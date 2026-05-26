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

  defstruct [:id, :name, :dirs, :created_at, :status]

  @type status :: :planning | :ongoing | :done | :archived

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          dirs: [String.t()],
          created_at: DateTime.t(),
          status: status()
        }

  @doc "Creates a new initiative with a random ID and the current UTC timestamp."
  def new(name, dirs \\ []) do
    %__MODULE__{
      id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      name: name,
      dirs: dirs,
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
    %{
      "id" => i.id,
      "name" => i.name,
      "dirs" => i.dirs,
      "created_at" => DateTime.to_iso8601(i.created_at),
      "status" => Atom.to_string(i.status || :ongoing)
    }
  end

  @doc "Deserialises an initiative from a plain map (as returned by JSON decoding)."
  def from_map(%{"id" => id, "name" => name, "dirs" => dirs, "created_at" => ts} = data) do
    {:ok, dt, _} = DateTime.from_iso8601(ts)
    status = data |> Map.get("status", "ongoing") |> parse_status()
    %__MODULE__{id: id, name: name, dirs: dirs, created_at: dt, status: status}
  end

  # Safe status deserialisation: unknown values (manual edits, downgrades) fall
  # back to :ongoing rather than raising ArgumentError and crashing Store.init/1.
  defp parse_status(s) when s in ["planning", "ongoing", "done", "archived"],
    do: String.to_existing_atom(s)

  defp parse_status(_), do: :ongoing
end

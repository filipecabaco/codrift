defmodule Codrift.Initiative do
  @moduledoc """
  Struct representing a named workspace that groups one or more directories.

  Multiple AI agents can run under one initiative, each scoped to its own
  directory but sharing the initiative's context.
  """

  defstruct [:id, :name, :dirs, :created_at]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          dirs: [String.t()],
          created_at: DateTime.t()
        }

  @doc "Creates a new initiative with a random ID and the current UTC timestamp."
  def new(name, dirs \\ []) do
    %__MODULE__{
      id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      name: name,
      dirs: dirs,
      created_at: DateTime.utc_now()
    }
  end

  @doc "Serialises an initiative to a plain map suitable for JSON encoding."
  def to_map(%__MODULE__{} = i) do
    %{
      "id" => i.id,
      "name" => i.name,
      "dirs" => i.dirs,
      "created_at" => DateTime.to_iso8601(i.created_at)
    }
  end

  @doc "Deserialises an initiative from a plain map (as returned by JSON decoding)."
  def from_map(%{"id" => id, "name" => name, "dirs" => dirs, "created_at" => ts}) do
    {:ok, dt, _} = DateTime.from_iso8601(ts)
    %__MODULE__{id: id, name: name, dirs: dirs, created_at: dt}
  end
end

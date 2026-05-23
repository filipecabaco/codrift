defmodule Codrift.Initiative do
  defstruct [:id, :name, :dirs, :created_at]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          dirs: [String.t()],
          created_at: DateTime.t()
        }

  def new(name, dirs \\ []) do
    %__MODULE__{
      id: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower),
      name: name,
      dirs: dirs,
      created_at: DateTime.utc_now()
    }
  end

  def to_map(%__MODULE__{} = i) do
    %{
      "id" => i.id,
      "name" => i.name,
      "dirs" => i.dirs,
      "created_at" => DateTime.to_iso8601(i.created_at)
    }
  end

  def from_map(%{"id" => id, "name" => name, "dirs" => dirs, "created_at" => ts}) do
    {:ok, dt, _} = DateTime.from_iso8601(ts)
    %__MODULE__{id: id, name: name, dirs: dirs, created_at: dt}
  end
end

defmodule Codrift.Initiative.Store do
  use GenServer

  alias Codrift.Initiative

  @default_path "~/.config/codrift/initiatives.json"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def create(name, dirs \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:create, name, dirs})
  end

  def get(id, server \\ __MODULE__) do
    GenServer.call(server, {:get, id})
  end

  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  def add_dir(id, dir, server \\ __MODULE__) do
    GenServer.call(server, {:add_dir, id, dir})
  end

  def remove_dir(id, dir, server \\ __MODULE__) do
    GenServer.call(server, {:remove_dir, id, dir})
  end

  def delete(id, server \\ __MODULE__) do
    GenServer.call(server, {:delete, id})
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, @default_path) |> Path.expand()
    {:ok, %{initiatives: load(path), path: path}}
  end

  @impl true
  def handle_call({:create, name, dirs}, _from, state) do
    initiative = Initiative.new(name, dirs)
    new_state = put_initiative(state, initiative)
    {:reply, {:ok, initiative}, new_state}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state.initiatives, id) do
      {:ok, initiative} -> {:reply, {:ok, initiative}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    initiatives = state.initiatives |> Map.values() |> Enum.sort_by(& &1.created_at, DateTime)
    {:reply, initiatives, state}
  end

  def handle_call({:add_dir, id, dir}, _from, state) do
    update_initiative(state, id, fn i ->
      %{i | dirs: Enum.uniq([dir | i.dirs])}
    end)
  end

  def handle_call({:remove_dir, id, dir}, _from, state) do
    update_initiative(state, id, fn i ->
      %{i | dirs: List.delete(i.dirs, dir)}
    end)
  end

  def handle_call({:delete, id}, _from, state) do
    case Map.pop(state.initiatives, id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {_, initiatives} ->
        new_state = %{state | initiatives: initiatives}
        persist(new_state)
        {:reply, :ok, new_state}
    end
  end

  defp put_initiative(state, initiative) do
    new_state = %{state | initiatives: Map.put(state.initiatives, initiative.id, initiative)}
    persist(new_state)
    new_state
  end

  defp update_initiative(state, id, fun) do
    case Map.fetch(state.initiatives, id) do
      {:ok, initiative} ->
        updated = fun.(initiative)
        new_state = put_initiative(state, updated)
        {:reply, {:ok, updated}, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp persist(%{initiatives: initiatives, path: path}) do
    data = Map.new(initiatives, fn {id, i} -> {id, Initiative.to_map(i)} end)
    json = JSON.encode!(%{"initiatives" => data})
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, json)
  end

  defp load(path) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, %{"initiatives" => raw}} <- JSON.decode(content) do
      Map.new(raw, fn {id, data} -> {id, Initiative.from_map(data)} end)
    else
      _ -> %{}
    end
  end
end

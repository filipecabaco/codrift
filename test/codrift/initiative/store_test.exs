defmodule Codrift.Initiative.StoreTest do
  use ExUnit.Case, async: true

  alias Codrift.Initiative
  alias Codrift.Initiative.Store

  @moduletag :tmp_dir

  defp start_store(tmp_dir) do
    path = Path.join(tmp_dir, "initiatives.json")
    start_supervised!({Store, path: path, name: nil})
  end

  describe "create/3" do
    test "creates an initiative with generated id and timestamp", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)

      assert {:ok, %Initiative{id: id, name: "My Project", dirs: []}} =
               Store.create("My Project", [], store)

      assert is_binary(id) and byte_size(id) == 16
    end

    test "creates an initiative with dirs", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      dirs = ["/home/user/project"]
      assert {:ok, %Initiative{dirs: ^dirs}} = Store.create("With Dirs", dirs, store)
    end
  end

  describe "get/2" do
    test "returns the initiative by id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Test", [], store)
      assert {:ok, %Initiative{name: "Test"}} = Store.get(id, store)
    end

    test "returns :not_found for unknown id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.get("nonexistent", store)
    end
  end

  describe "list/1" do
    test "returns empty list when no initiatives", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert [] = Store.list(store)
    end

    test "returns all initiatives sorted by created_at", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, first} = Store.create("First", [], store)
      :timer.sleep(2)
      {:ok, second} = Store.create("Second", [], store)

      assert [%{name: "First"}, %{name: "Second"}] = Store.list(store)
      assert DateTime.compare(first.created_at, second.created_at) == :lt
    end
  end

  describe "add_dir/3" do
    test "adds a directory to an initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Test", [], store)
      assert {:ok, %Initiative{dirs: ["/new/dir"]}} = Store.add_dir(id, "/new/dir", store)
    end

    test "is idempotent — duplicate dirs are ignored", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Test", [], store)
      Store.add_dir(id, "/dir", store)
      assert {:ok, %Initiative{dirs: ["/dir"]}} = Store.add_dir(id, "/dir", store)
    end

    test "returns :not_found for unknown id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.add_dir("bad", "/dir", store)
    end
  end

  describe "remove_dir/3" do
    test "removes a directory from an initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Test", ["/a", "/b"], store)
      assert {:ok, %Initiative{dirs: ["/a"]}} = Store.remove_dir(id, "/b", store)
    end

    test "is a no-op when dir is not present", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Test", ["/a"], store)
      assert {:ok, %Initiative{dirs: ["/a"]}} = Store.remove_dir(id, "/nonexistent", store)
    end
  end

  describe "delete/2" do
    test "removes an initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("To Delete", [], store)
      assert :ok = Store.delete(id, store)
      assert {:error, :not_found} = Store.get(id, store)
    end

    test "returns :not_found for unknown id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.delete("bad", store)
    end
  end

  describe "persistence" do
    test "data survives process restart", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "initiatives.json")

      store1 = start_supervised!({Store, path: path, name: nil}, id: :store1)
      {:ok, %{id: id}} = Store.create("Persistent", ["/dir"], store1)
      stop_supervised!(:store1)

      store2 = start_supervised!({Store, path: path, name: nil}, id: :store2)
      assert {:ok, %Initiative{name: "Persistent", dirs: ["/dir"]}} = Store.get(id, store2)
    end

    test "writes valid JSON to the configured path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "initiatives.json")
      store = start_store(tmp_dir)
      Store.create("JSON Test", [], store)

      assert {:ok, content} = File.read(path)
      assert {:ok, %{"initiatives" => _}} = JSON.decode(content)
    end
  end
end

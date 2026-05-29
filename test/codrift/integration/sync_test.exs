defmodule Codrift.Integration.SyncTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Initiative
  alias Codrift.Initiative.Store
  alias Codrift.Integration.Sync

  @moduletag :tmp_dir

  defp start_store(tmp_dir) do
    path = Path.join(tmp_dir, "initiatives.json")
    start_supervised!({Store, path: path, name: nil, context_dir_base: tmp_dir})
  end

  describe "run/1 with no linked initiatives" do
    test "is a no-op — no crash, no status changes", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, initiative} = Store.create("plain", [], store)

      assert :ok == Sync.run(store)

      assert {:ok, %Initiative{status: :ongoing}} = Store.get(initiative.id, store)
    end
  end

  describe "run/1 with a linked initiative whose service does not exist" do
    test "logs a warning and leaves status unchanged", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, initiative} = Store.create("linked", [], store)
      {:ok, _} = Store.link_integration(initiative.id, "no_such_service", "item-1", store)

      # Must not raise even though the service is invalid
      assert :ok == Sync.run(store)

      assert {:ok, %Initiative{status: :ongoing}} = Store.get(initiative.id, store)
    end
  end

  describe "run/1 mixed: only linked initiatives are touched" do
    test "unlinked initiatives are skipped", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, plain} = Store.create("no-link", [], store)
      {:ok, linked} = Store.create("linked", [], store)
      Store.set_status(plain.id, :planning, store)
      {:ok, _} = Store.link_integration(linked.id, "no_such_service", "item-1", store)

      Sync.run(store)

      # Plain initiative keeps its explicitly-set status
      assert {:ok, %Initiative{status: :planning}} = Store.get(plain.id, store)
    end
  end
end

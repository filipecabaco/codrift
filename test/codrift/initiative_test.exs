defmodule Codrift.InitiativeTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Initiative

  describe "to_map/1 and from_map/1" do
    test "roundtrips a plain initiative with no integration" do
      original = Initiative.new("my-project", ["/some/dir"])
      map = Initiative.to_map(original)

      assert {:ok, restored} = Initiative.from_map(map)
      assert restored.id == original.id
      assert restored.name == original.name
      assert restored.dirs == original.dirs
      assert restored.status == original.status
      assert is_nil(restored.integration)
    end

    test "roundtrips an initiative with an integration link" do
      original = %{
        Initiative.new("linked-project")
        | integration: %{service: "github", item_id: "owner/repo#42"}
      }

      map = Initiative.to_map(original)

      assert %{"integration" => %{"service" => "github", "item_id" => "owner/repo#42"}} = map
      assert {:ok, restored} = Initiative.from_map(map)
      assert %{service: "github", item_id: "owner/repo#42"} = restored.integration
    end

    test "integration key is absent from the map when integration is nil" do
      map = Initiative.new("no-link") |> Initiative.to_map()
      refute Map.has_key?(map, "integration")
    end

    test "from_map tolerates missing integration key (legacy data)" do
      map = %{
        "id" => "abc123",
        "name" => "legacy",
        "dirs" => [],
        "created_at" => "2024-01-01T00:00:00Z",
        "status" => "ongoing"
      }

      assert {:ok, %Initiative{integration: nil}} = Initiative.from_map(map)
    end

    test "from_map returns error for invalid ISO-8601 timestamp" do
      map = %{
        "id" => "abc",
        "name" => "bad",
        "dirs" => [],
        "created_at" => "not-a-date",
        "status" => "ongoing"
      }

      assert {:error, _} = Initiative.from_map(map)
    end

    test "from_map returns error for a malformed map" do
      assert {:error, {:invalid_initiative_map, _}} = Initiative.from_map(%{"id" => "only-id"})
    end
  end
end

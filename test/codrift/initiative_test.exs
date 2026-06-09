defmodule Codrift.InitiativeTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Initiative

  describe "create_temp/1" do
    @tag :tmp_dir
    test "builds a temp initiative from file paths", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "foo.ex")
      File.write!(file, "")

      initiative = Initiative.create_temp([file])

      assert initiative.status == :planning
      assert String.starts_with?(initiative.name, "tmp-")
      assert [%{path: ^tmp_dir}] = initiative.dirs
    end

    @tag :tmp_dir
    test "deduplicates dirs that share a parent", %{tmp_dir: tmp_dir} do
      for name <- ["a.ex", "b.ex"], do: File.write!(Path.join(tmp_dir, name), "")

      initiative =
        Initiative.create_temp([Path.join(tmp_dir, "a.ex"), Path.join(tmp_dir, "b.ex")])

      assert length(initiative.dirs) == 1
    end

    @tag :tmp_dir
    test "treats a directory path directly as a dir", %{tmp_dir: tmp_dir} do
      initiative = Initiative.create_temp([tmp_dir])

      assert [%{path: ^tmp_dir}] = initiative.dirs
    end
  end

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

    test "worktree_default roundtrips" do
      original = %{Initiative.new("wt-project") | worktree_default: true}
      map = Initiative.to_map(original)

      assert map["worktree_default"] == true
      assert {:ok, %Initiative{worktree_default: true}} = Initiative.from_map(map)
    end

    test "from_map defaults worktree_default to false for legacy data" do
      map = %{
        "id" => "abc123",
        "name" => "legacy",
        "dirs" => [],
        "created_at" => "2024-01-01T00:00:00Z",
        "status" => "ongoing"
      }

      assert {:ok, %Initiative{worktree_default: false}} = Initiative.from_map(map)
    end
  end
end

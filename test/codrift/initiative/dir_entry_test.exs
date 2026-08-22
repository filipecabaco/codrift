defmodule Codrift.Initiative.DirEntryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Initiative.DirEntry

  describe "new/2" do
    test "creates entry with defaults" do
      assert %DirEntry{path: "/a/b", worktree_enabled: false, worktree_path: nil} =
               DirEntry.new("/a/b")
    end

    test "creates entry with worktree opts" do
      assert %DirEntry{path: "/a/b", worktree_enabled: true, worktree_path: "/wt"} =
               DirEntry.new("/a/b", worktree_enabled: true, worktree_path: "/wt")
    end
  end

  describe "effective_path/1" do
    test "returns worktree_path when set" do
      entry = %DirEntry{path: "/source", worktree_path: "/wt"}
      assert DirEntry.effective_path(entry) == "/wt"
    end

    test "returns path when worktree_path is nil" do
      entry = %DirEntry{path: "/source", worktree_path: nil}
      assert DirEntry.effective_path(entry) == "/source"
    end
  end

  describe "to_map/1 and from_value/1 roundtrip" do
    test "plain entry without worktree" do
      original = DirEntry.new("/some/path")
      restored = original |> DirEntry.to_map() |> DirEntry.from_value()
      assert restored == original
    end

    test "entry with worktree" do
      original = DirEntry.new("/some/path", worktree_enabled: true, worktree_path: "/wt/path")
      restored = original |> DirEntry.to_map() |> DirEntry.from_value()
      assert restored == original
    end

    test "to_map omits worktree_path key when nil" do
      map = DirEntry.new("/path") |> DirEntry.to_map()
      refute Map.has_key?(map, "worktree_path")
    end

    test "to_map includes worktree_path when set" do
      map = DirEntry.new("/path", worktree_path: "/wt") |> DirEntry.to_map()
      assert map["worktree_path"] == "/wt"
    end
  end

  describe "from_value/1 migration" do
    test "accepts a plain string (legacy format)" do
      assert %DirEntry{path: "/legacy/dir", worktree_enabled: false, worktree_path: nil} =
               DirEntry.from_value("/legacy/dir")
    end

    test "accepts a map with only path (partial legacy)" do
      assert %DirEntry{path: "/some/dir", worktree_enabled: false, worktree_path: nil} =
               DirEntry.from_value(%{"path" => "/some/dir"})
    end

    test "accepts a full map" do
      assert %DirEntry{path: "/p", worktree_enabled: true, worktree_path: "/wt"} =
               DirEntry.from_value(%{
                 "path" => "/p",
                 "worktree_enabled" => true,
                 "worktree_path" => "/wt"
               })
    end
  end

  describe "resolve/2" do
    setup do
      entries = [
        DirEntry.new("/repos/api", worktree_enabled: true, worktree_path: "/wt/api"),
        DirEntry.new("/repos/web")
      ]

      {:ok, entries: entries}
    end

    test "a worktree-backed source path lands in the worktree", %{entries: entries} do
      assert DirEntry.resolve("/repos/api", entries) == "/wt/api"
    end

    test "is idempotent — resolving the worktree path returns it", %{entries: entries} do
      assert DirEntry.resolve("/wt/api", entries) == "/wt/api"
    end

    test "an entry without a worktree is left alone", %{entries: entries} do
      assert DirEntry.resolve("/repos/web", entries) == "/repos/web"
    end

    test "a directory that is not an entry passes through", %{entries: entries} do
      assert DirEntry.resolve("/somewhere/else", entries) == "/somewhere/else"
    end

    test "a subdirectory of a worktree-backed entry is NOT rewritten", %{entries: entries} do
      # Rewriting would assume the same relative path exists inside the
      # checkout; being wrong puts the agent somewhere nobody named.
      assert DirEntry.resolve("/repos/api/lib", entries) == "/repos/api/lib"
    end

    test "the path is expanded before matching", %{entries: entries} do
      assert DirEntry.resolve("/repos/api/../api", entries) == "/wt/api"
    end

    test "no entries at all is just an expansion" do
      assert DirEntry.resolve("/repos/api", []) == "/repos/api"
    end
  end
end

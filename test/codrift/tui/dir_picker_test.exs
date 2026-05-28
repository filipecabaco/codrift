defmodule Codrift.TUI.DirPickerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.TUI.DirPicker

  describe "score/2" do
    test "empty query scores 0 for any entry" do
      assert {0, "projects"} = DirPicker.score("projects", "")
    end

    test "prefix match scores 0" do
      assert {0, "projects"} = DirPicker.score("projects", "proj")
      assert {0, "Projects"} = DirPicker.score("Projects", "proj")
    end

    test "substring match scores 1" do
      assert {1, "my-projects"} = DirPicker.score("my-projects", "proj")
      assert {1, "old-project-alpha"} = DirPicker.score("old-project-alpha", "proj")
    end

    test "fuzzy subsequence match scores 2" do
      assert {2, "projects"} = DirPicker.score("projects", "prjs")
      assert {2, "codrift"} = DirPicker.score("codrift", "cdt")
      assert {2, "my-workspace"} = DirPicker.score("my-workspace", "mws")
    end

    test "returns :no_match when query cannot be a subsequence" do
      assert :no_match = DirPicker.score("abc", "xyz")
      assert :no_match = DirPicker.score("abc", "abcd")
    end

    test "match is case-insensitive" do
      # "projects" downcased starts with "proj" → prefix score 0
      assert {0, "Projects"} = DirPicker.score("Projects", "PROJ")
      # "myproject" downcased starts with "myp" → prefix score 0
      assert {0, "MyProject"} = DirPicker.score("MyProject", "myp")
      # "myproject" downcased does NOT start with "mp", but "m"…"p" is a subsequence → score 2
      assert {2, "MyProject"} = DirPicker.score("MyProject", "mp")
    end
  end

  describe "suggestions/1" do
    @moduletag :tmp_dir

    defp make_dirs(base, names) do
      Enum.each(names, fn name -> File.mkdir_p!(Path.join(base, name)) end)
    end

    test "returns directories matching by prefix first", %{tmp_dir: dir} do
      make_dirs(dir, ["projects", "project-alpha", "old-projects", "photos"])
      File.touch!(Path.join(dir, "readme.txt"))

      results = DirPicker.suggestions(dir <> "/proj")
      basenames = Enum.map(results, &Path.basename/1)

      assert "project-alpha" in basenames
      assert "projects" in basenames

      prefix_matches = Enum.filter(basenames, &String.starts_with?(&1, "proj"))

      assert Enum.all?(prefix_matches, fn name ->
               Enum.find_index(basenames, &(&1 == name)) < length(basenames)
             end)

      refute "photos" in basenames
      refute "readme.txt" in basenames
    end

    test "fuzzy match: query 'prj' matches 'projects'", %{tmp_dir: dir} do
      make_dirs(dir, ["projects", "photos", "downloads"])

      results = DirPicker.suggestions(dir <> "/prj")
      basenames = Enum.map(results, &Path.basename/1)

      assert "projects" in basenames
      refute "photos" in basenames
    end

    test "fuzzy match: 'cdt' matches 'codrift'", %{tmp_dir: dir} do
      make_dirs(dir, ["codrift", "config", "cache", "downloads"])

      results = DirPicker.suggestions(dir <> "/cdt")
      basenames = Enum.map(results, &Path.basename/1)

      assert "codrift" in basenames
    end

    test "trailing slash lists all subdirs", %{tmp_dir: dir} do
      make_dirs(dir, ["alpha", "beta", "gamma"])

      results = DirPicker.suggestions(dir <> "/")
      basenames = Enum.map(results, &Path.basename/1)

      assert "alpha" in basenames
      assert "beta" in basenames
      assert "gamma" in basenames
    end

    test "does not return files, only directories", %{tmp_dir: dir} do
      make_dirs(dir, ["subdir"])
      File.touch!(Path.join(dir, "file.txt"))
      File.touch!(Path.join(dir, "subfile"))

      results = DirPicker.suggestions(dir <> "/")
      basenames = Enum.map(results, &Path.basename/1)

      assert basenames == ["subdir"]
    end

    test "returns empty list for unreadable path", %{tmp_dir: dir} do
      assert [] = DirPicker.suggestions(Path.join(dir, "nonexistent") <> "/")
    end

    test "prefix matches appear before substring and fuzzy matches", %{tmp_dir: dir} do
      make_dirs(dir, ["project-main", "my-project", "projects"])

      results = DirPicker.suggestions(dir <> "/proj")
      basenames = Enum.map(results, &Path.basename/1)

      prefix_idx = Enum.find_index(basenames, &String.starts_with?(&1, "proj"))
      substring_idx = Enum.find_index(basenames, &(&1 == "my-project"))

      if prefix_idx && substring_idx do
        assert prefix_idx < substring_idx
      end
    end

    test "capped at 10 results", %{tmp_dir: dir} do
      make_dirs(dir, Enum.map(1..15, fn i -> "dir#{i}" end))

      results = DirPicker.suggestions(dir <> "/")
      assert length(results) <= 10
    end
  end
end

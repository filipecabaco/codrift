defmodule Codrift.DiffRenderTest do
  @moduledoc """
  The rendering half of `Codrift.Diff`: turning a parsed `FileDiff` back into
  something a person or the UI reads. `Codrift.DiffTest` covers parsing and
  generation; nothing exercised these.

  The interesting one is `to_split_rows/1`. Side-by-side rendering has to pair a
  run of removals against a run of additions, and the two runs are rarely the
  same length — an unbalanced pair that silently drops the longer side is a diff
  that hides a line of someone's change.
  """
  use ExUnit.Case, async: true

  alias Codrift.Diff
  alias Codrift.Diff.{FileDiff, Hunk, Line}

  defp line(type, content), do: %Line{type: type, content: content}

  defp file_diff(lines, attrs \\ []) do
    hunk = %Hunk{
      old_start: 1,
      old_count: 5,
      new_start: 1,
      new_count: 6,
      header: "@@ -1,5 +1,6 @@",
      lines: lines
    }

    struct!(
      %FileDiff{
        path: "lib/foo.ex",
        old_path: "lib/foo.ex",
        hunks: [hunk],
        additions: Enum.count(lines, &(&1.type == :add)),
        deletions: Enum.count(lines, &(&1.type == :remove))
      },
      attrs
    )
  end

  describe "to_split_rows/1" do
    test "opens each hunk with its header on both sides" do
      rows = Diff.to_split_rows(file_diff([line(:context, "unchanged")]))

      assert [{:header, "@@ -1,5 +1,6 @@", "@@ -1,5 +1,6 @@"} | _] = rows
    end

    test "a context line appears on both sides" do
      [_header, row] = Diff.to_split_rows(file_diff([line(:context, "same")]))

      assert {:context, "same", "same"} == row
    end

    test "a balanced change pairs each removal with its replacement" do
      rows =
        Diff.to_split_rows(
          file_diff([
            line(:remove, "old a"),
            line(:remove, "old b"),
            line(:add, "new a"),
            line(:add, "new b")
          ])
        )

      assert [_header, {:change, "old a", "new a"}, {:change, "old b", "new b"}] = rows
    end

    test "more additions than removals pads the old side rather than dropping them" do
      rows =
        Diff.to_split_rows(
          file_diff([
            line(:remove, "old"),
            line(:add, "new 1"),
            line(:add, "new 2"),
            line(:add, "new 3")
          ])
        )

      changes = Enum.filter(rows, &match?({:change, _, _}, &1))

      assert [
               {:change, "old", "new 1"},
               {:change, nil, "new 2"},
               {:change, nil, "new 3"}
             ] == changes
    end

    test "more removals than additions pads the new side" do
      rows =
        Diff.to_split_rows(
          file_diff([
            line(:remove, "old 1"),
            line(:remove, "old 2"),
            line(:add, "new")
          ])
        )

      changes = Enum.filter(rows, &match?({:change, _, _}, &1))
      assert [{:change, "old 1", "new"}, {:change, "old 2", nil}] == changes
    end

    test "a pure deletion has nothing on the new side" do
      rows = Diff.to_split_rows(file_diff([line(:remove, "gone")]))
      assert [_header, {:change, "gone", nil}] = rows
    end

    test "a pure addition has nothing on the old side" do
      rows = Diff.to_split_rows(file_diff([line(:add, "brand new")]))
      assert [_header, {:change, nil, "brand new"}] = rows
    end

    test "interleaved adds and removes are grouped, not zipped in arrival order" do
      # git emits removals before additions within a chunk, but the parser makes
      # no such promise — the grouping has to survive either order.
      rows =
        Diff.to_split_rows(
          file_diff([
            line(:add, "new"),
            line(:remove, "old")
          ])
        )

      assert [_header, {:change, "old", "new"}] = rows
    end

    test "context between two changes separates them into their own groups" do
      rows =
        Diff.to_split_rows(
          file_diff([
            line(:remove, "a"),
            line(:add, "A"),
            line(:context, "middle"),
            line(:remove, "b"),
            line(:add, "B")
          ])
        )

      assert [
               {:header, _, _},
               {:change, "a", "A"},
               {:context, "middle", "middle"},
               {:change, "b", "B"}
             ] = rows
    end

    test "a file with no hunks renders no rows" do
      assert [] == Diff.to_split_rows(file_diff([]) |> Map.put(:hunks, []))
    end

    test "every hunk contributes its own header" do
      hunk = fn header ->
        %Hunk{
          old_start: 1,
          old_count: 1,
          new_start: 1,
          new_count: 1,
          header: header,
          lines: [line(:context, "x")]
        }
      end

      diff = %FileDiff{
        path: "f",
        old_path: "f",
        additions: 0,
        deletions: 0,
        hunks: [hunk.("@@ -1 +1 @@"), hunk.("@@ -9 +9 @@")]
      }

      headers = for {:header, h, _} <- Diff.to_split_rows(diff), do: h
      assert ["@@ -1 +1 @@", "@@ -9 +9 @@"] == headers
    end
  end

  describe "to_unified/1" do
    test "reassembles a patch with the file header and the line prefixes" do
      patch =
        Diff.to_unified(
          file_diff([
            line(:context, "keep"),
            line(:remove, "old"),
            line(:add, "new")
          ])
        )

      assert patch == """
             --- a/lib/foo.ex
             +++ b/lib/foo.ex
             @@ -1,5 +1,6 @@
              keep
             -old
             +new\
             """
    end

    test "a new file keeps the /dev/null old path the parser gave it" do
      patch = Diff.to_unified(file_diff([line(:add, "hello")], old_path: "/dev/null"))

      assert patch =~ "--- a//dev/null"
      assert patch =~ "+++ b/lib/foo.ex"
    end

    test "round-trips: parsing the output yields the same lines" do
      original = file_diff([line(:context, "keep"), line(:remove, "old"), line(:add, "new")])

      [reparsed] =
        original
        |> Diff.to_unified()
        |> then(&("diff --git a/lib/foo.ex b/lib/foo.ex\n" <> &1))
        |> Diff.parse()

      assert Enum.map(reparsed.hunks |> hd() |> Map.fetch!(:lines), &{&1.type, &1.content}) ==
               [{:context, "keep"}, {:remove, "old"}, {:add, "new"}]
    end
  end

  describe "to_map/1" do
    test "serialises to the string-keyed shape the RPC layer sends" do
      map = Diff.to_map(file_diff([line(:add, "new"), line(:remove, "old")]))

      assert map["path"] == "lib/foo.ex"
      assert map["old_path"] == "lib/foo.ex"
      assert map["additions"] == 1
      assert map["deletions"] == 1

      assert [hunk] = map["hunks"]
      assert hunk["old_start"] == 1
      assert hunk["new_count"] == 6
      assert hunk["header"] == "@@ -1,5 +1,6 @@"
    end

    test "line types become strings, since JSON has no atoms" do
      map =
        Diff.to_map(file_diff([line(:add, "a"), line(:remove, "r"), line(:context, "c")]))

      types = map["hunks"] |> hd() |> Map.fetch!("lines") |> Enum.map(& &1["type"])
      assert ["add", "remove", "context"] == types
    end

    test "survives JSON encoding, which is the only reason it exists" do
      map = Diff.to_map(file_diff([line(:add, "new")]))
      assert map == map |> JSON.encode!() |> JSON.decode!()
    end
  end
end

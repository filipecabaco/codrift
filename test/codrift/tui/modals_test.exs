defmodule Codrift.TUI.ModalsTest do
  use ExUnit.Case, async: true

  alias Codrift.TUI.Modals

  @actions [
    %{id: :new_initiative, label: "New Initiative", hint: "n"},
    %{id: :add_dir, label: "Add Directory", hint: "a"},
    %{id: :delete_current, label: "Delete / Stop Current", hint: "d"},
    %{id: :toggle_sidebar, label: "Toggle Sidebar", hint: "Ctrl+B"},
    %{id: :refresh, label: "Refresh", hint: "r"}
  ]

  describe "filter_actions/2" do
    test "empty query returns all actions unchanged" do
      assert @actions == Modals.filter_actions(@actions, "")
    end

    test "case-insensitive partial match on label" do
      result = Modals.filter_actions(@actions, "dir")
      labels = Enum.map(result, & &1.label)
      assert "Add Directory" in labels
      refute "New Initiative" in labels
      refute "Refresh" in labels
    end

    test "uppercase query matches lowercase characters in label" do
      result = Modals.filter_actions(@actions, "SIDEBAR")
      assert [%{label: "Toggle Sidebar"}] = result
    end

    test "no match returns empty list" do
      assert [] = Modals.filter_actions(@actions, "zzz_no_match")
    end

    test "query matching multiple labels returns all of them" do
      # "e" appears in New Initiative, Delete / Stop Current, Toggle Sidebar, Refresh
      result = Modals.filter_actions(@actions, "e")
      labels = Enum.map(result, & &1.label)

      assert "New Initiative" in labels
      assert "Delete / Stop Current" in labels
      assert "Toggle Sidebar" in labels
      assert "Refresh" in labels
    end

    test "filter against an empty actions list returns empty" do
      assert [] = Modals.filter_actions([], "anything")
    end

    test "match is on the label field only — hint content does not affect results" do
      # "Ctrl+B" is the hint for Toggle Sidebar; searching for "ctrl" should not match
      result = Modals.filter_actions(@actions, "ctrl")
      assert [] = result
    end
  end
end

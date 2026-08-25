defmodule Codrift.Integration.ItemTest do
  @moduledoc """
  The pure edges of `Codrift.Integration`: the shapes every adapter's output is
  funnelled through before the rest of the app sees it.

  These have no HTTP in them, which is exactly why they are worth pinning —
  `merge_sources/1` decides whether one dead service hides the others, and
  `map_item_status/1` decides what an imported issue's status becomes.
  """
  use ExUnit.Case, async: true

  alias Codrift.Integration
  alias Codrift.Integration.Item

  defp item(id, attrs \\ %{}) do
    struct!(
      %Item{id: id, title: "title #{id}", url: "https://example.test/#{id}", metadata: %{}},
      attrs
    )
  end

  describe "Item.presence/1" do
    test "nil stays nil" do
      assert nil == Item.presence(nil)
    end

    test "an empty or whitespace-only string becomes nil" do
      # Trackers return "" as readily as null, and only nil triggers the
      # "no description" fallbacks downstream.
      assert nil == Item.presence("")
      assert nil == Item.presence("   ")
      assert nil == Item.presence("\n\t ")
    end

    test "real text is returned untouched, surrounding whitespace included" do
      assert "hello" == Item.presence("hello")
      assert " hello " == Item.presence(" hello ")
    end
  end

  describe "relation tagging" do
    test "tag_relation/2 records why each item is in the queue" do
      [a, b] = Integration.tag_relation([item("1"), item("2")], "created")

      assert Integration.relation(a) == "created"
      assert Integration.relation(b) == "created"
    end

    test "tag_relation/2 keeps the metadata already on the item" do
      [tagged] = Integration.tag_relation([item("1", %{metadata: %{keep: :me}})], "assigned")

      assert tagged.metadata.keep == :me
      assert Integration.relation(tagged) == "assigned"
    end

    test "relation/1 defaults to assigned when nothing tagged it" do
      assert Integration.relation(item("1")) == "assigned"
    end
  end

  describe "merge_sources/1" do
    test "flattens every successful source and tags each with its relation" do
      {:ok, items} =
        Integration.merge_sources([
          {"assigned", {:ok, [item("1")]}},
          {"created", {:ok, [item("2")]}}
        ])

      assert Enum.map(items, & &1.id) == ["1", "2"]
      assert Enum.map(items, &Integration.relation/1) == ["assigned", "created"]
    end

    test "an item in two sources is kept once, under the first relation" do
      # Assigned-and-created is the common case for your own issues, and it must
      # not show up twice in the picker.
      {:ok, items} =
        Integration.merge_sources([
          {"assigned", {:ok, [item("1")]}},
          {"created", {:ok, [item("1")]}}
        ])

      assert [only] = items
      assert Integration.relation(only) == "assigned"
    end

    test "one dead source never hides the ones that answered" do
      {:ok, items} =
        Integration.merge_sources([
          {"assigned", {:error, :timeout}},
          {"created", {:ok, [item("2")]}}
        ])

      assert Enum.map(items, & &1.id) == ["2"]
    end

    test "an error comes back only when every source failed" do
      assert {:error, :timeout} =
               Integration.merge_sources([
                 {"assigned", {:error, :timeout}},
                 {"created", {:error, :nope}}
               ])
    end

    test "no sources at all is an empty queue, not an error" do
      assert {:ok, []} = Integration.merge_sources([])
    end
  end

  describe "map_item_status/1" do
    test "finished work becomes :done" do
      for status <- ~w[done closed completed resolved merged fixed] do
        assert :done == Integration.map_item_status(status), "#{status} should be done"
      end
    end

    test "abandoned work becomes :archived" do
      for status <- ~w[cancelled canceled archived wontfix dismissed] do
        assert :archived == Integration.map_item_status(status), "#{status} should be archived"
      end
    end

    test "not-started work becomes :planning" do
      for status <- ~w[planning backlog todo unstarted triage icebox] do
        assert :planning == Integration.map_item_status(status), "#{status} should be planning"
      end
    end

    test "anything else — including nil — is treated as in progress" do
      assert :ongoing == Integration.map_item_status("in progress")
      assert :ongoing == Integration.map_item_status("Doing")
      assert :ongoing == Integration.map_item_status(nil)
    end
  end

  describe "valid_services/0" do
    test "names every registered adapter, and each one resolves back" do
      services = Integration.valid_services()

      assert "github" in services
      assert "linear" in services
      assert services == Enum.uniq(services)

      for service <- services do
        assert {:ok, _adapter} = Integration.adapter_for(service, skip_credentials: true)
      end
    end

    test "an unknown service is an error, not a crash" do
      assert {:error, _} = Integration.adapter_for("not-a-service", skip_credentials: true)
    end
  end
end

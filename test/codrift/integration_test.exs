defmodule Codrift.IntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Integration
  alias Codrift.Integration.Item

  describe "adapter_for/1" do
    test "returns the module for every registered service" do
      for service <- Integration.valid_services() do
        assert {:ok, mod} = Integration.adapter_for(service)
        assert is_atom(mod)
      end
    end

    test "returns an error for an unknown service" do
      assert {:error, msg} = Integration.adapter_for("nonexistent")
      assert String.contains?(msg, "nonexistent")
    end

    test "error message lists valid services" do
      {:error, msg} = Integration.adapter_for("nope")
      for service <- Integration.valid_services(), do: assert(String.contains?(msg, service))
    end
  end

  describe "valid_services/0" do
    test "returns a non-empty list of strings" do
      services = Integration.valid_services()
      assert is_list(services)
      assert services != []
      assert Enum.all?(services, &is_binary/1)
    end

    test "includes expected services" do
      services = Integration.valid_services()
      assert "github" in services
      assert "linear" in services
      assert "gitlab" in services
      assert "jira" in services
      assert "notion" in services
      refute "shortcut" in services
    end
  end

  describe "map_item_status/1" do
    test "maps closed/done variants to :done" do
      for s <- ~w[done closed completed resolved merged fixed] do
        assert Integration.map_item_status(s) == :done, "expected :done for #{inspect(s)}"
      end
    end

    test "maps cancelled/archived variants to :archived" do
      for s <- ~w[cancelled canceled archived wontfix won't_fix dismissed] do
        assert Integration.map_item_status(s) == :archived, "expected :archived for #{inspect(s)}"
      end
    end

    test "maps planning/backlog variants to :planning" do
      for s <- ~w[planning backlog todo unstarted triage icebox] do
        assert Integration.map_item_status(s) == :planning, "expected :planning for #{inspect(s)}"
      end
    end

    test "maps nil and unknown values to :ongoing" do
      assert Integration.map_item_status(nil) == :ongoing
      assert Integration.map_item_status("in_progress") == :ongoing
      assert Integration.map_item_status("open") == :ongoing
      assert Integration.map_item_status("some_random_status") == :ongoing
    end
  end

  describe "Item struct" do
    test "requires :id, :title, :url" do
      assert_raise ArgumentError, fn ->
        struct!(Item, id: "1", title: "t")
      end
    end

    test "metadata defaults to empty map" do
      item = %Item{id: "1", title: "t", url: "http://x"}
      assert item.metadata == %{}
    end

    test "linked_prs and labels default to nil (set explicitly when building)" do
      item = %Item{id: "1", title: "t", url: "http://x"}
      assert is_nil(item.linked_prs)
      assert is_nil(item.labels)
    end
  end

  describe "write_integration_files/4" do
    @tag :tmp_dir
    test "writes integration.json and integration.md under the given id", %{tmp_dir: _tmp_dir} do
      id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      base = Path.expand("~/.codrift/initiatives/#{id}")
      context = "# My Issue\n\n**Status:** open\n"

      on_exit(fn -> File.rm_rf!(base) end)

      assert :ok = Integration.write_integration_files(id, "github", "owner/repo#5", context)

      assert {:ok, meta_raw} = File.read(Path.join(base, "integration.json"))
      assert {:ok, %{"service" => "github", "item_id" => "owner/repo#5"}} = JSON.decode(meta_raw)

      assert {:ok, ^context} = File.read(Path.join(base, "integration.md"))
    end

    @tag :tmp_dir
    test "overwrites existing files on second call", %{tmp_dir: _tmp_dir} do
      id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      base = Path.expand("~/.codrift/initiatives/#{id}")
      on_exit(fn -> File.rm_rf!(base) end)

      Integration.write_integration_files(id, "github", "repo#1", "old content")
      Integration.write_integration_files(id, "linear", "ENG-2", "new content")

      assert {:ok, meta} = File.read(Path.join(base, "integration.json"))
      assert {:ok, %{"service" => "linear", "item_id" => "ENG-2"}} = JSON.decode(meta)
      assert {:ok, "new content"} = File.read(Path.join(base, "integration.md"))
    end
  end
end

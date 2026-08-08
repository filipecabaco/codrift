defmodule Codrift.Integration.AssignedTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Initiative
  alias Codrift.Initiative.Store
  alias Codrift.Integration
  alias Codrift.Integration.Item

  @moduletag :tmp_dir

  defmodule Linear do
    @moduledoc false
    @behaviour Codrift.Integration

    alias Codrift.Integration.Item

    @impl true
    def name, do: "stub_linear"

    @impl true
    def credentials?, do: true

    @impl true
    def list_items(_opts \\ []), do: {:ok, []}

    @impl true
    def list_assigned(_opts \\ []) do
      Codrift.Integration.merge_sources([
        {"assigned", {:ok, [item("ENG-1", "Fix login redirect")]}},
        {"created",
         {:ok, [item("ENG-1", "Fix login redirect"), item("ENG-2", "Rate limit the API")]}}
      ])
    end

    @impl true
    def get_item(id, _opts \\ []), do: {:ok, item(id, "Fix login redirect")}

    @impl true
    def to_initiative_context(%Item{} = i), do: "# #{i.title}\n\n**Source:** stub — #{i.url}\n"

    defp item(id, title) do
      %Item{
        id: id,
        title: title,
        description: "why it matters",
        url: "https://linear.test/#{id}",
        labels: ["bug"],
        status: "backlog",
        assignee: "me",
        linked_prs: []
      }
    end
  end

  defmodule GitHub do
    @moduledoc false
    @behaviour Codrift.Integration

    alias Codrift.Integration.Item

    @impl true
    def name, do: "stub_github"

    @impl true
    def credentials?, do: true

    @impl true
    def list_items(_opts \\ []), do: {:ok, []}

    @impl true
    def list_assigned(_opts \\ []) do
      {:ok,
       [
         %Item{
           id: "acme/web#42",
           title: "Flaky checkout test",
           url: "https://github.test/acme/web/issues/42",
           labels: [],
           status: "open",
           assignee: "me",
           linked_prs: []
         }
       ]}
    end

    @impl true
    def get_item(_id, _opts \\ []), do: {:error, "not used"}

    @impl true
    def to_initiative_context(%Item{} = i), do: "# #{i.title}\n"
  end

  defmodule Disconnected do
    @moduledoc false
    @behaviour Codrift.Integration

    @impl true
    def name, do: "stub_disconnected"

    @impl true
    def credentials?, do: false

    @impl true
    def list_items(_opts \\ []), do: {:ok, []}

    @impl true
    def list_assigned(_opts \\ []), do: raise("must not be queried without credentials")

    @impl true
    def get_item(_id, _opts \\ []), do: {:error, "not used"}

    @impl true
    def to_initiative_context(_item), do: ""
  end

  defmodule Unconfigured do
    @moduledoc false
    @behaviour Codrift.Integration

    @impl true
    def name, do: "stub_unconfigured"

    @impl true
    def credentials?, do: true

    @impl true
    def list_items(_opts \\ []), do: {:ok, []}

    @impl true
    def list_assigned(_opts \\ []), do: {:error, :not_configured}

    @impl true
    def get_item(_id, _opts \\ []), do: {:error, "not used"}

    @impl true
    def to_initiative_context(_item), do: ""
  end

  defmodule Broken do
    @moduledoc false
    @behaviour Codrift.Integration

    @impl true
    def name, do: "stub_broken"

    @impl true
    def credentials?, do: true

    @impl true
    def list_items(_opts \\ []), do: {:ok, []}

    @impl true
    def list_assigned(_opts \\ []), do: {:error, "HTTP 401: bad credentials"}

    @impl true
    def get_item(_id, _opts \\ []), do: {:error, "not used"}

    @impl true
    def to_initiative_context(_item), do: ""
  end

  defp start_store(tmp_dir) do
    path = Path.join(tmp_dir, "initiatives.json")
    start_supervised!({Store, path: path, name: nil, context_dir_base: tmp_dir})
  end

  defp cleanup_context_dir(id) do
    on_exit(fn -> File.rm_rf!(Codrift.Paths.initiative_dir(id)) end)
  end

  describe "list_assigned/1" do
    test "gathers items from every credentialed service, tagged with their service" do
      assert %{items: items, errors: []} =
               Integration.list_assigned(initiatives: [], adapters: [Linear, GitHub])

      assert [
               %{service: "stub_linear", item: %Item{id: "ENG-1"}, initiative_id: nil},
               %{service: "stub_github", item: %Item{id: "acme/web#42"}, initiative_id: nil},
               %{service: "stub_linear", item: %Item{id: "ENG-2"}, initiative_id: nil}
             ] = items
    end

    test "tags why each item is in the queue and puts assigned work first" do
      assert %{items: items} =
               Integration.list_assigned(initiatives: [], adapters: [Linear])

      assert [
               %{item: %Item{id: "ENG-1"}, relation: "assigned"},
               %{item: %Item{id: "ENG-2"}, relation: "created"}
             ] = items
    end

    test "skips services without credentials" do
      assert %{items: items, errors: []} =
               Integration.list_assigned(initiatives: [], adapters: [Disconnected, GitHub])

      assert [%{service: "stub_github"}] = items
    end

    test "reports failing services but still returns the rest" do
      assert %{items: items, errors: errors} =
               Integration.list_assigned(initiatives: [], adapters: [Broken, GitHub])

      assert [%{service: "stub_github"}] = items
      assert [%{service: "stub_broken", reason: "HTTP 401: bad credentials"}] = errors
    end

    test "treats :not_configured as nothing to offer, not as an error" do
      assert %{items: [], errors: []} =
               Integration.list_assigned(initiatives: [], adapters: [Unconfigured])
    end

    test "points already-imported items at their initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, initiative} = Store.create("Fix login redirect", [], store)

      {:ok, linked} =
        Store.link_integration(initiative.id, %{service: "stub_linear", item_id: "ENG-1"}, store)

      assert %{items: items} =
               Integration.list_assigned(initiatives: [linked], adapters: [Linear])

      assert [
               %{item: %Item{id: "ENG-1"}, initiative_id: id},
               %{item: %Item{id: "ENG-2"}, initiative_id: nil}
             ] = items

      assert id == initiative.id
    end
  end

  describe "merge_sources/1" do
    test "keeps the first relation an item matched" do
      one = %Item{id: "1", title: "t", url: "u"}

      assert {:ok, [merged]} =
               Integration.merge_sources([{"assigned", {:ok, [one]}}, {"created", {:ok, [one]}}])

      assert Integration.relation(merged) == "assigned"
    end

    test "one failing source does not hide the others" do
      one = %Item{id: "1", title: "t", url: "u"}

      assert {:ok, [_]} =
               Integration.merge_sources([
                 {"assigned", {:error, "HTTP 403"}},
                 {"created", {:ok, [one]}}
               ])
    end

    test "returns the error when every source failed" do
      assert {:error, "HTTP 403"} =
               Integration.merge_sources([
                 {"assigned", {:error, "HTTP 403"}},
                 {"created", {:error, "HTTP 500"}}
               ])
    end
  end

  describe "imported_index/1" do
    test "falls back to integration.json for initiatives linked before the store recorded it" do
      id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      cleanup_context_dir(id)
      :ok = Integration.write_integration_files(id, "stub_linear", "ENG-9", "# ctx\n")

      initiative = %Initiative{Initiative.new("legacy") | id: id}

      assert %{{"stub_linear", "ENG-9"} => ^id} = Integration.imported_index([initiative])
    end

    test "ignores initiatives with no integration at all" do
      assert Integration.imported_index([Initiative.new("plain")]) == %{}
    end
  end

  describe "import_item/3" do
    test "links the initiative and maps the remote status", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)

      assert {:ok, :imported, initiative} =
               Integration.import_item("stub_linear", "ENG-1",
                 store: store,
                 adapters: [Linear]
               )

      cleanup_context_dir(initiative.id)

      assert %Initiative{
               name: "Fix login redirect",
               status: :planning,
               integration: %{
                 service: "stub_linear",
                 item_id: "ENG-1",
                 url: "https://linear.test/ENG-1"
               }
             } = initiative

      assert {:ok, context} = File.read(Integration.context_path(initiative.id))
      assert context =~ "Fix login redirect"
    end

    test "one initiative per external item — a second import returns the first", %{
      tmp_dir: tmp_dir
    } do
      store = start_store(tmp_dir)
      opts = [store: store, adapters: [Linear]]

      assert {:ok, :imported, first} = Integration.import_item("stub_linear", "ENG-1", opts)
      cleanup_context_dir(first.id)

      assert {:ok, :existing, again} = Integration.import_item("stub_linear", "ENG-1", opts)

      assert again.id == first.id
      assert [_only_one] = Store.list(store)
    end
  end
end

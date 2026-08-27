defmodule Codrift.CoreOpenFileTest do
  @moduledoc """
  `open_file` — the MCP command that pins a file of interest into an initiative
  and asks the window to open it.

  The half that is easy to get wrong is the round trip: a pin is only useful if
  the file it names can then be *read* as a context file, which means the two
  operations have to agree about which roots a link may cross.

  Not `async`: `Core.call/2` goes through the globally-named store.
  """
  use ExUnit.Case, async: false

  alias Codrift.Core

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    {:ok, initiative} = Core.call("create_initiative", %{"name" => "open-file-test"})
    id = initiative["id"]
    {:ok, _} = Core.call("add_dir", %{"initiative_id" => id, "dir" => repo})
    on_exit(fn -> Core.call("delete_initiative", %{"initiative_id" => id}) end)
    {:ok, initiative_id: id, repo: repo}
  end

  defp write!(dir, rel, content) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  test "pins the file, lists it, and reads it back", %{initiative_id: id, repo: repo} do
    path = write!(repo, "lib/router.ex", "defmodule Router do end")

    assert {:ok, %{"name" => "router.ex", "existing" => false}} =
             Core.call("open_file", %{"initiative_id" => id, "path" => path})

    assert {:ok, %{"files" => files}} = Core.call("list_context_files", %{"initiative_id" => id})
    assert "router.ex" in files

    assert {:ok, %{"content" => "defmodule Router do end"}} =
             Core.call("read_context_file", %{"initiative_id" => id, "name" => "router.ex"})
  end

  test "honours an explicit name", %{initiative_id: id, repo: repo} do
    path = write!(repo, "lib/router.ex", "x")

    assert {:ok, %{"name" => "the-router.ex"}} =
             Core.call("open_file", %{
               "initiative_id" => id,
               "path" => path,
               "name" => "the-router.ex"
             })
  end

  test "refuses a file outside the initiative's directories", %{initiative_id: id, tmp_dir: tmp} do
    path = write!(Path.join(tmp, "elsewhere"), "secrets.env", "TOKEN=1")

    assert {:error, message} = Core.call("open_file", %{"initiative_id" => id, "path" => path})
    assert message =~ "not inside any of this initiative's directories"
  end

  test "refuses a directory", %{initiative_id: id, repo: repo} do
    assert {:error, message} =
             Core.call("open_file", %{"initiative_id" => id, "path" => Path.join(repo, "lib")})

    assert message =~ "not a regular file"
  end

  test "reports an unknown initiative", %{repo: repo} do
    path = write!(repo, "lib/router.ex", "x")

    assert {:error, "initiative not found: nope"} =
             Core.call("open_file", %{"initiative_id" => "nope", "path" => path})
  end

  test "is exposed as an MCP tool" do
    assert "open_file" in Codrift.MCP.Handler.tool_names()
  end
end

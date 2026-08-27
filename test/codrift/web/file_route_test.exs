defmodule Codrift.Web.FileRouteTest do
  @moduledoc """
  `GET /api/file` — the only read that is not an op on `/api/rpc`, because
  `<img src>` cannot POST.

  What matters here is that it is not a hole: it answers for images inside a
  directory the initiative actually holds, and for nothing else. Not `async`:
  it goes through the globally-named initiative store.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias Codrift.Core

  @moduletag :tmp_dir

  @opts Codrift.init([])

  # A one-pixel PNG, so the bytes that come back are recognisably the ones that
  # went in rather than a truncated or re-encoded copy.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>

  setup %{tmp_dir: tmp} do
    {:ok, initiative} = Core.call("create_initiative", %{"name" => "file-route-test"})
    id = initiative["id"]
    {:ok, _} = Core.call("add_dir", %{"initiative_id" => id, "dir" => tmp})
    on_exit(fn -> Core.call("delete_initiative", %{"initiative_id" => id}) end)
    {:ok, initiative_id: id}
  end

  defp fetch(id, path) do
    conn(:get, "/api/file", %{"initiative_id" => id, "path" => path})
    |> Codrift.call(@opts)
  end

  test "serves an image with its content type", %{initiative_id: id, tmp_dir: tmp} do
    path = Path.join(tmp, "shot.png")
    File.write!(path, @png)

    conn = fetch(id, path)

    assert conn.status == 200
    assert conn.resp_body == @png
    assert {"content-type", "image/png" <> _} = List.keyfind(conn.resp_headers, "content-type", 0)
  end

  # The editor writes over the file this pane is previewing, so a cached copy
  # would keep showing the picture that used to be there.
  test "asks the browser to revalidate", %{initiative_id: id, tmp_dir: tmp} do
    path = Path.join(tmp, "shot.png")
    File.write!(path, @png)

    assert {"cache-control", "no-cache"} =
             fetch(id, path).resp_headers |> List.keyfind("cache-control", 0)
  end

  test "refuses a path outside the initiative's directories", %{initiative_id: id} do
    outside = Path.join(System.tmp_dir!(), "codrift-route-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    path = Path.join(outside, "elsewhere.png")
    File.write!(path, @png)

    assert fetch(id, path).status == 403
  end

  test "refuses a file that is not a renderable image", %{initiative_id: id, tmp_dir: tmp} do
    path = Path.join(tmp, "id_rsa")
    File.write!(path, "PRIVATE KEY")

    assert fetch(id, path).status == 415
  end

  test "404s for a missing file", %{initiative_id: id, tmp_dir: tmp} do
    assert fetch(id, Path.join(tmp, "absent.png")).status == 404
  end

  # Where agents drop screenshots. It is not in `dirs`, but `list_context_files`
  # offers it, so the pane would otherwise list a picture it could not show.
  test "serves an image from the initiative's context folder", %{initiative_id: id} do
    context = Codrift.Initiative.Store.context_path(id)
    path = Path.join(context, "screenshot.png")
    File.write!(path, @png)

    conn = fetch(id, path)

    assert conn.status == 200
    assert conn.resp_body == @png
  end

  test "404s for an unknown initiative", %{tmp_dir: tmp} do
    path = Path.join(tmp, "shot.png")
    File.write!(path, @png)

    assert fetch("nonexistent", path).status == 404
  end
end

defmodule Codrift.CoreWorkspaceDirTest do
  @moduledoc """
  The default workspace folder: the one setting that changes what another
  operation does, so the contract worth pinning is that `list_dirs` honours it
  and that a bad path never reaches disk.

  Not `async`: reads and writes the single sandbox `settings.json`.
  """
  use ExUnit.Case, async: false

  alias Codrift.Config.Settings
  alias Codrift.Core

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:codrift, :data_dir)
    Application.put_env(:codrift, :data_dir, Path.join(tmp_dir, "data"))
    on_exit(fn -> Application.put_env(:codrift, :data_dir, previous) end)
    :ok
  end

  test "is unset until someone sets it" do
    assert {:ok, %{"path" => nil}} = Core.call("get_workspace_dir", %{})
  end

  test "round-trips a real directory", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace)

    assert {:ok, %{"path" => ^workspace}} =
             Core.call("set_workspace_dir", %{"path" => workspace})

    assert {:ok, %{"path" => ^workspace}} = Core.call("get_workspace_dir", %{})
  end

  test "rejects a path that is not a directory, leaving the old one in place", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace)
    Core.call("set_workspace_dir", %{"path" => workspace})

    assert {:error, message} = Core.call("set_workspace_dir", %{"path" => "/nope/not/here"})
    assert message =~ "not a directory"
    assert Settings.workspace_dir() == workspace
  end

  test "an empty path clears the preference rather than storing it", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace)
    Core.call("set_workspace_dir", %{"path" => workspace})

    assert {:ok, %{"path" => nil}} = Core.call("set_workspace_dir", %{"path" => "   "})
    assert Settings.workspace_dir() == nil
  end

  test "list_dirs starts from the workspace folder when no path is given", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(Path.join(workspace, "alpha"))
    File.mkdir_p!(Path.join(workspace, "beta"))
    Core.call("set_workspace_dir", %{"path" => workspace})

    assert {:ok, %{base: base, entries: ["alpha", "beta"]}} = Core.call("list_dirs", %{})
    assert base == Path.expand(workspace)
  end

  test "a blank path is treated as no path, not as the working directory", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(Path.join(workspace, "alpha"))
    Core.call("set_workspace_dir", %{"path" => workspace})

    assert {:ok, %{entries: ["alpha"]}} = Core.call("list_dirs", %{"path" => ""})
    assert {:ok, %{entries: ["alpha"]}} = Core.call("list_dirs", %{"path" => "  "})
  end

  test "an explicit path still wins over the workspace folder", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    elsewhere = Path.join(tmp_dir, "elsewhere")
    File.mkdir_p!(Path.join(workspace, "alpha"))
    File.mkdir_p!(Path.join(elsewhere, "gamma"))
    Core.call("set_workspace_dir", %{"path" => workspace})

    assert {:ok, %{entries: ["gamma"]}} = Core.call("list_dirs", %{"path" => elsewhere <> "/"})
  end
end

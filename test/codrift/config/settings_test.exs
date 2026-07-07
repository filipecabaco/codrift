defmodule Codrift.Config.SettingsTest do
  # async: false — reads/writes the single sandbox settings.json.
  use ExUnit.Case, async: false

  alias Codrift.Config.Settings

  setup do
    # data_dir/0 is a runtime sandbox override; resolve the path at runtime.
    path = Path.join(Codrift.Paths.data_dir(), "settings.json")
    File.mkdir_p!(Path.dirname(path))
    File.rm_rf(path)
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, path: path}
  end

  test "profiles/0 and profile/1 read launch profiles from settings.json", %{path: path} do
    File.write!(
      path,
      JSON.encode!(%{
        "profiles" => %{
          "claude-work" => %{
            "adapter" => "claude",
            "env" => %{"CLAUDE_CONFIG_DIR" => "~/.claude-work"}
          }
        }
      })
    )

    assert %{"claude-work" => %{"adapter" => "claude"}} = Settings.profiles()

    assert {:ok, %{"adapter" => "claude", "env" => %{"CLAUDE_CONFIG_DIR" => "~/.claude-work"}}} =
             Settings.profile("claude-work")

    assert {:error, :not_found} = Settings.profile("nope")
  end

  test "profiles/0 defaults to empty when there is no settings file", %{path: path} do
    File.rm_rf(path)
    assert Settings.profiles() == %{}
  end
end

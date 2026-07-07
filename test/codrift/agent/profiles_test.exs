defmodule Codrift.Agent.ProfilesTest do
  # async: false — reads/writes the single sandbox settings.json.
  use ExUnit.Case, async: false

  alias Codrift.Core

  setup do
    path = Path.join(Codrift.Paths.data_dir(), "settings.json")
    File.mkdir_p!(Path.dirname(path))
    File.rm_rf(path)
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, path: path}
  end

  test "list_agent_profiles returns configured profiles sorted by name", %{path: path} do
    File.write!(
      path,
      JSON.encode!(%{
        "profiles" => %{
          "claude-work" => %{"adapter" => "claude"},
          "claude-personal" => %{"adapter" => "claude"}
        }
      })
    )

    assert {:ok,
            [
              %{name: "claude-personal", adapter: "claude"},
              %{name: "claude-work", adapter: "claude"}
            ]} = Core.call("list_agent_profiles", %{})
  end

  test "list_agent_profiles is empty with no profiles configured" do
    assert {:ok, []} = Core.call("list_agent_profiles", %{})
  end

  test "start_agent with an unknown profile errors before spawning anything" do
    assert {:error, reason} =
             Core.call("start_agent", %{
               "initiative_id" => "irrelevant",
               "adapter" => "claude",
               "profile" => "ghost"
             })

    assert reason =~ "unknown launch profile"
  end
end

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

  test "save_agent_profile writes a profile the launcher can resolve", %{path: path} do
    assert {:ok, %{"name" => "claude-personal"}} =
             Core.call("save_agent_profile", %{
               "name" => "claude-personal",
               "adapter" => "claude",
               "env" => %{"CLAUDE_CONFIG_DIR" => "~/.claude-personal"}
             })

    assert %{"profiles" => %{"claude-personal" => stored}} =
             path |> File.read!() |> JSON.decode!()

    assert stored == %{
             "adapter" => "claude",
             "env" => %{"CLAUDE_CONFIG_DIR" => "~/.claude-personal"}
           }

    assert {:ok, [%{name: "claude-personal", adapter: "claude"}]} =
             Core.call("list_agent_profiles", %{})
  end

  test "get_agent_profiles returns the env the config view edits" do
    Core.call("save_agent_profile", %{
      "name" => "codex-work",
      "adapter" => "codex",
      "env" => %{"CODEX_HOME" => "~/.codex-work"}
    })

    assert {:ok, %{"profiles" => [profile]}} = Core.call("get_agent_profiles", %{})

    assert profile == %{
             name: "codex-work",
             adapter: "codex",
             command: nil,
             args: [],
             env: %{"CODEX_HOME" => "~/.codex-work"}
           }
  end

  test "a profile's args survive the round trip, blanks dropped", %{path: path} do
    assert {:ok, %{"args" => ["--model", "opus"]}} =
             Core.call("save_agent_profile", %{
               "name" => "claude-opus",
               "adapter" => "claude",
               "args" => ["--model", "  ", "opus"]
             })

    assert %{"profiles" => %{"claude-opus" => %{"args" => ["--model", "opus"]}}} =
             path |> File.read!() |> JSON.decode!()

    assert {:ok, %{"profiles" => [%{args: ["--model", "opus"]}]}} =
             Core.call("get_agent_profiles", %{})

    assert {:ok, _} =
             Core.call("save_agent_profile", %{
               "name" => "claude-opus",
               "adapter" => "claude",
               "args" => []
             })

    assert %{"profiles" => %{"claude-opus" => stored}} = path |> File.read!() |> JSON.decode!()
    refute Map.has_key?(stored, "args")
  end

  test "save_agent_profile rejects args that are not strings" do
    assert {:error, reason} =
             Core.call("save_agent_profile", %{
               "name" => "bad-args",
               "adapter" => "claude",
               "args" => ["--model", 3]
             })

    assert reason =~ "each argument must be a string"
  end

  test "a profile's command replaces the adapter's executable, and must exist" do
    assert {:error, reason} =
             Core.call("save_agent_profile", %{
               "name" => "ghost-cmd",
               "adapter" => "claude",
               "command" => "definitely-not-on-this-path"
             })

    assert reason =~ "command not found"

    assert {:ok, _} =
             Core.call("save_agent_profile", %{
               "name" => "claude-sh",
               "adapter" => "claude",
               "command" => "sh"
             })

    assert {:ok, %{"profiles" => [%{name: "claude-sh", command: "sh"}]}} =
             Core.call("get_agent_profiles", %{})
  end

  test "save_agent_profile rejects names that would shadow a base adapter" do
    assert {:error, reason} =
             Core.call("save_agent_profile", %{"name" => "claude", "adapter" => "claude"})

    assert reason =~ "base adapter"
    assert {:ok, []} = Core.call("list_agent_profiles", %{})
  end

  test "save_agent_profile rejects unknown adapters and malformed env" do
    assert {:error, "unknown adapter: nope"} =
             Core.call("save_agent_profile", %{"name" => "mine", "adapter" => "nope"})

    assert {:error, reason} =
             Core.call("save_agent_profile", %{
               "name" => "mine",
               "adapter" => "claude",
               "env" => %{"not a var" => "x"}
             })

    assert reason =~ "invalid environment variable name"
  end

  # A rename must not leave the old name behind: it would keep launching under
  # config the user just moved away from.
  test "save_agent_profile with previous_name renames in place" do
    Core.call("save_agent_profile", %{
      "name" => "old",
      "adapter" => "claude",
      "env" => %{"CLAUDE_CONFIG_DIR" => "~/.claude-old"}
    })

    assert {:ok, _} =
             Core.call("save_agent_profile", %{
               "name" => "new",
               "adapter" => "claude",
               "env" => %{"CLAUDE_CONFIG_DIR" => "~/.claude-new"},
               "previous_name" => "old"
             })

    assert {:ok, [%{name: "new"}]} = Core.call("list_agent_profiles", %{})
  end

  # The rejected half of a rename: the original has to survive, or a typo in the
  # new name would delete a working profile.
  test "a rejected rename leaves the original profile untouched" do
    Core.call("save_agent_profile", %{"name" => "keeper", "adapter" => "claude"})

    assert {:error, _} =
             Core.call("save_agent_profile", %{
               "name" => "bad name",
               "adapter" => "claude",
               "previous_name" => "keeper"
             })

    assert {:ok, [%{name: "keeper"}]} = Core.call("list_agent_profiles", %{})
  end

  test "delete_agent_profile removes it, and reports an unknown name" do
    Core.call("save_agent_profile", %{"name" => "temp", "adapter" => "claude"})

    assert {:ok, %{"deleted" => "temp"}} = Core.call("delete_agent_profile", %{"name" => "temp"})
    assert {:ok, []} = Core.call("list_agent_profiles", %{})

    assert {:error, reason} = Core.call("delete_agent_profile", %{"name" => "temp"})
    assert reason =~ "unknown launch profile"
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

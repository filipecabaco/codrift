defmodule Codrift.CoreValidationTest do
  @moduledoc """
  The guards on `Codrift.Core` — the branches that run when an argument is
  wrong rather than when everything is right.

  These matter more than usual here. `Core.call/2` is reachable from MCP, which
  means the arguments are written by a *model*: a path with `..` in it, a
  profile name with a slash, an env map with a non-string value. A guard that
  is missing shows up as a file written outside the initiative folder or a
  crash where an error was owed, and neither is visible until it happens.

  Not `async`: uses the global `Codrift.Initiative.Store` and the sandboxed
  settings file.
  """
  use ExUnit.Case, async: false

  alias Codrift.Core
  alias Codrift.Initiative.Store

  # There is no write RPC — files land in the initiative folder from the editor
  # or an agent, and Core only lists and reads them.
  defp write!(id, name, content) do
    path = Path.join(Store.context_path(id), name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  setup do
    {:ok, initiative} = Core.call("create_initiative", %{"name" => "validation-test"})
    id = initiative["id"]
    on_exit(fn -> Store.delete(id) end)
    {:ok, id: id}
  end

  describe "context file paths" do
    test "a relative path inside the folder is read back", %{id: id} do
      write!(id, "notes.md", "hello")

      assert {:ok, %{"content" => "hello"}} =
               Core.call("read_context_file", %{"initiative_id" => id, "name" => "notes.md"})
    end

    test "a nested path is listed — an initiative folder is a real workspace", %{id: id} do
      write!(id, "docs/runbook.md", "steps")

      assert {:ok, %{"files" => files}} =
               Core.call("list_context_files", %{"initiative_id" => id})

      assert "docs/runbook.md" in files

      assert {:ok, %{"content" => "steps"}} =
               Core.call("read_context_file", %{
                 "initiative_id" => id,
                 "name" => "docs/runbook.md"
               })
    end

    test "escaping the initiative folder is refused", %{id: id} do
      # The whole point of the guard: an argument written by a model must not be
      # able to name a file outside the folder it was given.
      for name <- ["../escape.md", "docs/../../escape.md", "..", "."] do
        assert {:error, _} =
                 Core.call("read_context_file", %{"initiative_id" => id, "name" => name}),
               "read accepted #{inspect(name)}"
      end
    end

    test "an absolute path is refused", %{id: id} do
      assert {:error, _} =
               Core.call("read_context_file", %{"initiative_id" => id, "name" => "/etc/passwd"})
    end

    test "an empty name is refused", %{id: id} do
      assert {:error, _} = Core.call("read_context_file", %{"initiative_id" => id, "name" => ""})
    end

    test "reading a file that is not there reports it rather than crashing", %{id: id} do
      assert {:error, _} =
               Core.call("read_context_file", %{"initiative_id" => id, "name" => "nope.md"})
    end
  end

  describe "launch profiles" do
    test "a profile round-trips through save and get" do
      on_exit(fn -> Core.call("delete_agent_profile", %{"name" => "test-profile"}) end)

      assert {:ok, saved} =
               Core.call("save_agent_profile", %{
                 "name" => "test-profile",
                 "adapter" => "claude",
                 "command" => "sh",
                 "args" => ["--model", "opus"],
                 "env" => %{"CLAUDE_CONFIG_DIR" => "~/.claude-work"}
               })

      assert saved["name"] == "test-profile"
      assert saved["command"] == "sh"
      assert saved["args"] == ["--model", "opus"]

      # `get_agent_profiles` builds atom-keyed maps while `save_agent_profile`
      # returns string-keyed ones. Both are JSON-encoded before anyone outside
      # sees them, so this is a note rather than a complaint — but a test that
      # assumed one shape for both would fail for the wrong reason.
      assert {:ok, %{"profiles" => profiles}} = Core.call("get_agent_profiles", %{})
      assert Enum.any?(profiles, &(&1.name == "test-profile"))
    end

    test "a name that could escape the settings file is refused" do
      for name <- ["", "   ", "with/slash", "with space"] do
        assert {:error, _} =
                 Core.call("save_agent_profile", %{"name" => name, "adapter" => "claude"}),
               "accepted profile name #{inspect(name)}"
      end
    end

    test "a non-string name or adapter is an error, not a crash" do
      assert {:error, _} = Core.call("save_agent_profile", %{"name" => 42, "adapter" => "claude"})
      assert {:error, _} = Core.call("save_agent_profile", %{"name" => "ok", "adapter" => 42})
    end

    test "an unknown adapter is refused, so a profile cannot name a tool that does not exist" do
      assert {:error, message} =
               Core.call("save_agent_profile", %{"name" => "ghost", "adapter" => "not-a-tool"})

      assert is_binary(message)
    end

    test "args must be a list of strings" do
      assert {:error, _} =
               Core.call("save_agent_profile", %{
                 "name" => "bad-args",
                 "adapter" => "claude",
                 "args" => "--model opus"
               })
    end

    test "env must be an object of name to value" do
      assert {:error, _} =
               Core.call("save_agent_profile", %{
                 "name" => "bad-env",
                 "adapter" => "claude",
                 "env" => ["CLAUDE_CONFIG_DIR=~/x"]
               })
    end

    test "deleting a profile that was never there is reported" do
      assert {:error, message} = Core.call("delete_agent_profile", %{"name" => "never-existed"})
      assert message =~ "unknown launch profile"
    end
  end

  describe "the agent an initiative launches" do
    test "a base adapter is accepted", %{id: id} do
      assert {:ok, %{"agent" => "codex"}} =
               Core.call("set_initiative_agent", %{"initiative_id" => id, "agent" => "codex"})
    end

    test "an unknown choice is refused rather than stored", %{id: id} do
      assert {:error, _} =
               Core.call("set_initiative_agent", %{
                 "initiative_id" => id,
                 "agent" => "not-an-agent"
               })
    end

    test "a non-string choice is an error, not a crash", %{id: id} do
      assert {:error, _} =
               Core.call("set_initiative_agent", %{"initiative_id" => id, "agent" => 42})
    end

    test "the default agent rejects an unknown choice too" do
      assert {:error, _} = Core.call("set_default_agent", %{"agent" => "not-an-agent"})
    end
  end

  describe "initiative status" do
    test "each valid status is accepted", %{id: id} do
      for status <- ~w[planning ongoing done archived] do
        assert {:ok, %{"status" => ^status}} =
                 Core.call("set_initiative_status", %{"initiative_id" => id, "status" => status})
      end
    end

    test "an invalid status is refused", %{id: id} do
      assert {:error, _} =
               Core.call("set_initiative_status", %{"initiative_id" => id, "status" => "somehow"})
    end
  end

  describe "operations on an initiative that does not exist" do
    test "report it rather than raising" do
      calls = [
        {"list_context_files", %{"initiative_id" => "nope"}},
        {"read_context_file", %{"initiative_id" => "nope", "name" => "x.md"}},
        {"get_diff", %{"initiative_id" => "nope"}},
        {"set_initiative_status", %{"initiative_id" => "nope", "status" => "done"}},
        {"add_dir", %{"initiative_id" => "nope", "dir" => "/tmp"}},
        {"delete_initiative", %{"initiative_id" => "nope"}}
      ]

      for {op, args} <- calls do
        assert {:error, message} = Core.call(op, args),
               "#{op} did not report a missing initiative"

        assert message =~ "not found", "#{op} gave an unhelpful message: #{message}"
      end
    end
  end
end

defmodule Codrift.ClaudePermissionsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.ClaudePermissions

  @moduletag :tmp_dir

  describe "add/2" do
    test "creates .claude/settings.json and adds the rule", %{tmp_dir: tmp_dir} do
      result = ClaudePermissions.add(tmp_dir, "Read")

      assert result == ["Read"]
      assert File.exists?(Path.join([tmp_dir, ".claude", "settings.json"]))

      {:ok, content} = File.read(Path.join([tmp_dir, ".claude", "settings.json"]))
      {:ok, map} = JSON.decode(content)
      assert get_in(map, ["permissions", "allow"]) == ["Read"]
    end

    test "is idempotent — adding the same rule twice is safe", %{tmp_dir: tmp_dir} do
      ClaudePermissions.add(tmp_dir, "Read")
      result = ClaudePermissions.add(tmp_dir, "Read")

      assert result == ["Read"]
    end

    test "preserves existing rules", %{tmp_dir: tmp_dir} do
      ClaudePermissions.add(tmp_dir, "Bash(git *)")
      result = ClaudePermissions.add(tmp_dir, "Read")

      assert "Read" in result
      assert "Bash(git *)" in result
    end

    test "preserves other settings keys", %{tmp_dir: tmp_dir} do
      settings_path = Path.join([tmp_dir, ".claude", "settings.json"])
      File.mkdir_p!(Path.dirname(settings_path))
      File.write!(settings_path, JSON.encode!(%{"theme" => "dark"}))

      ClaudePermissions.add(tmp_dir, "Read")

      {:ok, content} = File.read(settings_path)
      {:ok, map} = JSON.decode(content)
      assert map["theme"] == "dark"
      assert get_in(map, ["permissions", "allow"]) == ["Read"]
    end
  end

  describe "remove/2" do
    test "removes the rule from the allow list", %{tmp_dir: tmp_dir} do
      ClaudePermissions.add(tmp_dir, "Read")
      result = ClaudePermissions.remove(tmp_dir, "Read")

      assert result == []
      {:ok, content} = File.read(Path.join([tmp_dir, ".claude", "settings.json"]))
      {:ok, map} = JSON.decode(content)
      assert get_in(map, ["permissions", "allow"]) == []
    end

    test "is a no-op when the rule is not present", %{tmp_dir: tmp_dir} do
      ClaudePermissions.add(tmp_dir, "Bash(git *)")
      result = ClaudePermissions.remove(tmp_dir, "Read")

      assert result == ["Bash(git *)"]
    end

    test "is a no-op when the file does not exist", %{tmp_dir: tmp_dir} do
      assert ClaudePermissions.remove(tmp_dir, "Read") == []
    end

    test "preserves other rules when removing one", %{tmp_dir: tmp_dir} do
      ClaudePermissions.add(tmp_dir, "Read")
      ClaudePermissions.add(tmp_dir, "Bash(git *)")
      result = ClaudePermissions.remove(tmp_dir, "Read")

      refute "Read" in result
      assert "Bash(git *)" in result
    end
  end

  describe "allow_list/1" do
    test "returns empty list when no settings file exists", %{tmp_dir: tmp_dir} do
      assert ClaudePermissions.allow_list(tmp_dir) == []
    end

    test "returns current allow list", %{tmp_dir: tmp_dir} do
      ClaudePermissions.add(tmp_dir, "Read")
      ClaudePermissions.add(tmp_dir, "Bash(git *)")

      list = ClaudePermissions.allow_list(tmp_dir)
      assert "Read" in list
      assert "Bash(git *)" in list
    end
  end
end

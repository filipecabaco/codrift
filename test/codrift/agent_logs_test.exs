defmodule Codrift.AgentLogsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.AgentLogs

  defp write_log(agent_id, content) do
    path = Codrift.Paths.agent_log("logs-test-init", agent_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp unique_id(prefix), do: "#{prefix}-#{:erlang.unique_integer([:positive])}"

  describe "tail/2" do
    test "returns the contents of an agent's transcript log" do
      id = unique_id("tail")
      write_log(id, "hello transcript")

      assert {:ok, "hello transcript"} = AgentLogs.tail(id)
    end

    test "returns only the last max_bytes of a large log" do
      id = unique_id("tail-cap")
      write_log(id, String.duplicate("x", 90) <> "TAIL-END")

      assert {:ok, tail} = AgentLogs.tail(id, 8)
      assert tail == "TAIL-END"
    end

    test "returns :not_found for unknown agents" do
      assert {:error, :not_found} = AgentLogs.tail(unique_id("missing"))
    end

    test "rejects ids containing path separators or traversal" do
      write_log(unique_id("safe"), "data")

      assert {:error, :not_found} = AgentLogs.tail("../../../etc/passwd")
      assert {:error, :not_found} = AgentLogs.tail("foo/bar")
      assert {:error, :not_found} = AgentLogs.tail("*")
      assert {:error, :not_found} = AgentLogs.tail(nil)
    end
  end
end

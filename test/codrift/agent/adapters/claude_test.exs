defmodule Codrift.Agent.Adapters.ClaudeTest do
  use ExUnit.Case, async: true

  alias Codrift.Agent.Adapters.Claude

  test "implements Codrift.Agent behaviour" do
    assert function_exported?(Claude, :cmd, 0)
    assert function_exported?(Claude, :args, 1)
    assert function_exported?(Claude, :env, 1)
    assert function_exported?(Claude, :parse_status, 1)
  end

  test "args/1 returns a list of strings" do
    assert is_list(Claude.args("/some/dir"))
    assert Enum.all?(Claude.args("/some/dir"), &is_binary/1)
  end

  test "env/1 returns a list of tuples" do
    env = Claude.env("/some/dir")
    assert is_list(env)
    assert Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end)
  end

  test "parse_status returns :awaiting_input on prompt line" do
    assert :awaiting_input = Claude.parse_status("some output\n> ")
  end

  test "parse_status returns :running on Running output" do
    assert :running = Claude.parse_status("Running some tool...")
  end

  test "parse_status returns nil for unrecognized output" do
    assert nil == Claude.parse_status("just some random log line")
  end
end

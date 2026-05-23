defmodule Codrift.Agent.Adapters.ClaudeTest do
  use ExUnit.Case, async: true

  alias Codrift.Agent.Adapters.Claude

  test "args/1 returns a list of strings" do
    args = Claude.args("/some/dir")
    assert is_list(args)
    assert Enum.all?(args, &is_binary/1)
  end

  test "env/1 returns a list of {string, string} tuples" do
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

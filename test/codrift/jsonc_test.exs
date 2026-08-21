defmodule Codrift.JSONCTest do
  use ExUnit.Case, async: true

  alias Codrift.JSONC

  describe "strip_comments/1" do
    test "keeps `//` inside string literals" do
      assert ~s({"$schema": "https://opencode.ai/config.json"}) ==
               JSONC.strip_comments(~s({"$schema": "https://opencode.ai/config.json"}))
    end

    test "removes a `//` line comment but keeps the newline" do
      assert "{\n\n  \"a\": 1\n}" == JSONC.strip_comments("{\n// note\n  \"a\": 1\n}")
    end

    test "removes a trailing `//` comment after a value" do
      assert ~s({"a": 1 \n}) == JSONC.strip_comments(~s({"a": 1 // why\n}))
    end

    test "removes `/* */` block comments, including multi-line" do
      assert ~s({"a": 1}) == JSONC.strip_comments(~s({/* one */"a": /* two\nthree */1}))
    end

    test "keeps comment markers and escaped quotes inside strings" do
      assert ~s({"a": "/* not a comment */", "b": "say \\" // no"}) ==
               JSONC.strip_comments(~s({"a": "/* not a comment */", "b": "say \\" // no"}))
    end

    test "leaves comment-free JSON untouched" do
      assert ~s({"a": [1, 2], "b": {"c": null}}) ==
               JSONC.strip_comments(~s({"a": [1, 2], "b": {"c": null}}))
    end

    test "preserves multi-byte characters" do
      assert ~s({"name": "Codrift — ✓"}) == JSONC.strip_comments(~s({"name": "Codrift — ✓"}))
    end
  end

  describe "decode!/1" do
    test "decodes the opencode config that `codrift mcp install` writes" do
      content = ~s({\n  "$schema": "https://opencode.ai/config.json"\n})

      assert %{"$schema" => "https://opencode.ai/config.json"} = JSONC.decode!(content)
    end

    test "decodes a commented config" do
      content = """
      {
        // the codrift SSE endpoint
        "mcp": {"codrift": {"type": "sse", "url": "http://localhost:43117/mcp"}}
      }
      """

      assert %{"mcp" => %{"codrift" => %{"url" => "http://localhost:43117/mcp"}}} =
               JSONC.decode!(content)
    end

    test "raises on genuinely malformed JSON" do
      assert_raise JSON.DecodeError, fn -> JSONC.decode!(~s({"a": })) end
    end
  end
end

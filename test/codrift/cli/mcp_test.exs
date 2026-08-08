defmodule Codrift.CLI.MCPTest do
  @moduledoc """
  Coverage for `codrift mcp install`, which rewrites config files that belong
  to other tools. Two things previously broke users: the registered URL pointed
  at a port nothing listens on, and the rewrite minified (and, for JSONC,
  de-commented) the file it merged into.

  Not `async`: `resolve_port/1` reads the shared `:codrift` application env.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Codrift.CLI.MCP

  @entry %{"type" => "remote", "url" => "http://localhost:43117/mcp/sse"}

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "config.json")}
  end

  defp merge(path, opts \\ []) do
    decode = Keyword.get(opts, :decode, &JSON.decode!/1)
    capture_io(fn -> MCP.merge_into(path, decode, %{}, "mcp", @entry) end)
  end

  defp read_json(path), do: path |> File.read!() |> JSON.decode!()

  describe "resolve_port/1" do
    test "an explicit --port= flag wins" do
      assert MCP.resolve_port(["--port=1234"]) == 1234
    end

    test "falls back to the port the server is configured to bind" do
      previous = Application.get_env(:codrift, :bandit_opts)
      Application.put_env(:codrift, :bandit_opts, ip: {127, 0, 0, 1}, port: 43_117)
      on_exit(fn -> Application.put_env(:codrift, :bandit_opts, previous) end)

      assert MCP.resolve_port([]) == 43_117
    end

    test "ignores the ephemeral port the test env binds" do
      previous = Application.get_env(:codrift, :bandit_opts)
      Application.put_env(:codrift, :bandit_opts, port: 0)
      on_exit(fn -> Application.put_env(:codrift, :bandit_opts, previous) end)

      assert MCP.resolve_port([]) == 43_117
    end
  end

  describe "merge_into/5" do
    test "creates the file when it does not exist", %{path: path} do
      assert merge(path) =~ "Added codrift to mcp"
      assert read_json(path) == %{"mcp" => %{"codrift" => @entry}}
    end

    test "keeps unrelated keys and sibling servers", %{path: path} do
      File.write!(path, ~s({"theme":"dark","mcp":{"other":{"type":"local"}}}))
      merge(path)

      assert %{
               "theme" => "dark",
               "mcp" => %{"other" => %{"type" => "local"}, "codrift" => @entry}
             } = read_json(path)
    end

    test "writes readable JSON rather than a single minified line", %{path: path} do
      merge(path)
      content = File.read!(path)

      assert String.contains?(content, "\n")
      assert content =~ ~r/^\{\n/
    end

    test "leaves a .bak of the previous contents", %{path: path} do
      original = ~s({"theme":"dark"})
      File.write!(path, original)
      merge(path)

      assert File.read!(path <> ".bak") == original
    end

    test "refuses to touch a file it cannot parse", %{path: path} do
      broken = ~s({"theme": "dark",,,})
      File.write!(path, broken)

      output = merge(path)

      assert output =~ "not valid JSON"
      assert output =~ "left untouched"
      assert File.read!(path) == broken
    end

    test "warns that a JSONC rewrite drops comments", %{path: path} do
      File.write!(path, ~s({\n  // keep me\n  "theme": "dark"\n}))

      output = merge(path, decode: &Codrift.JSONC.decode!/1)

      assert output =~ "comments in config.json are dropped on rewrite"
      assert read_json(path)["theme"] == "dark"
    end

    test "is idempotent across repeated installs", %{path: path} do
      merge(path)
      first = File.read!(path)
      merge(path)

      assert File.read!(path) == first
    end
  end
end

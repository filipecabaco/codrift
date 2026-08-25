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

  @entry %{"type" => "remote", "url" => "http://localhost:43117/mcp"}

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

  # A launch profile that sets CLAUDE_CONFIG_DIR gives its agents their own
  # config directory, which a plain `codrift mcp install` never writes to. These
  # cover the three decisions that make `--profile` register in the right place:
  # which profiles were asked for, where that profile's config lives, and whether
  # the server is already there.
  describe "registered?/1 and listing_line/1" do
    # `claude mcp list` output is another program's human-facing text, so the
    # match has to survive its indentation and the servers listed around ours.
    @listing """
    Checking MCP server health...

      some-other: https://example.test/mcp - ✓ Connected
      codrift: http://localhost:43117/mcp - ✓ Connected
    """

    test "finds our entry among the others" do
      assert MCP.registered?(@listing)
      assert MCP.listing_line(@listing) =~ "codrift: http://localhost:43117/mcp"
    end

    test "a listing without us is not a false positive" do
      without = "  some-other: https://example.test/mcp - ✓ Connected\n"

      refute MCP.registered?(without)
      assert MCP.listing_line(without) == nil
    end

    test "a server whose name merely contains ours does not count" do
      # `codrift-staging:` starts with our name as a substring but is a
      # different server; the colon is what makes the match exact.
      refute MCP.registered?("  codrift-staging: http://localhost:1/mcp\n")
    end

    test "empty output is simply not registered" do
      refute MCP.registered?("")
      assert MCP.listing_line("") == nil
    end
  end

  describe "profile_selection/1" do
    setup do
      path = Path.join(Codrift.Paths.data_dir(), "settings.json")
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        JSON.encode!(%{
          "profiles" => %{
            "work" => %{"adapter" => "claude"},
            "personal" => %{"adapter" => "claude"}
          }
        })
      )

      on_exit(fn -> File.rm_rf(path) end)
      :ok
    end

    test "no flag means the default config directory" do
      assert MCP.profile_selection([]) == :default
      assert MCP.profile_selection(["--port=1234"]) == :default
    end

    test "--profile= selects exactly that one, without consulting settings" do
      assert MCP.profile_selection(["--profile=work"]) == {:profiles, ["work"]}
    end

    test "--all-profiles expands to every configured profile, sorted" do
      assert MCP.profile_selection(["--all-profiles"]) == {:profiles, ["personal", "work"]}
    end

    test "--all-profiles wins over --profile= when both are passed" do
      assert MCP.profile_selection(["--profile=work", "--all-profiles"]) ==
               {:profiles, ["personal", "work"]}
    end
  end

  describe "profile_config_dir/1" do
    test "expands the ~ that settings.json stores verbatim" do
      profile = %{"env" => %{"CLAUDE_CONFIG_DIR" => "~/.claude-work"}}

      dir = MCP.profile_config_dir(profile)

      assert dir == Path.expand("~/.claude-work")
      refute String.contains?(dir, "~")
    end

    # No directory of its own means the profile shares the default config, which
    # `codrift mcp install` already registered. Reporting that beats registering
    # the same file twice and calling it a fresh success.
    test "is nil when the profile sets no config directory" do
      assert MCP.profile_config_dir(%{"adapter" => "claude"}) == nil
      assert MCP.profile_config_dir(%{"env" => %{}}) == nil
      assert MCP.profile_config_dir(%{"env" => %{"OTHER" => "x"}}) == nil
    end

    test "treats an empty value as absent rather than as the current directory" do
      assert MCP.profile_config_dir(%{"env" => %{"CLAUDE_CONFIG_DIR" => ""}}) == nil
    end
  end

  # The listing line is what `status` now prints verbatim. Collapsing it to
  # "registered" is what let a server every client hung on keep reporting itself
  # as installed and fine — the words "Failed to connect" were in hand and
  # thrown away.
  describe "listing_line/1" do
    test "returns the server's own line, health verdict included" do
      output = """
      Checking MCP server health...

        other: https://example.com/mcp (HTTP) - connected
        codrift: http://localhost:43117/mcp (HTTP) - X Failed to connect
      """

      assert MCP.listing_line(output) =~ "Failed to connect"
    end

    test "is nil when the server is not in the listing" do
      refute MCP.listing_line("other: https://example.com/mcp (HTTP) - connected\n")
    end

    test "does not return a different server that merely mentions the name" do
      refute MCP.listing_line("codrift-staging: http://localhost:1/mcp - connected\n")
    end
  end

  describe "registered?/1" do
    test "matches the server on its own listing line" do
      assert MCP.registered?("""
             other: https://example.com/mcp (HTTP) - connected
             codrift: http://localhost:43117/mcp (HTTP) - connected
             """)
    end

    test "tolerates the indentation and health suffixes claude prints" do
      assert MCP.registered?("Checking MCP server health...\n\n  codrift: http://x - ok\n")
    end

    test "is false when nothing is registered" do
      refute MCP.registered?("")
      refute MCP.registered?("other: https://example.com/mcp (HTTP) - connected\n")
    end

    # The reason this is anchored rather than a substring search: another server
    # whose name merely contains ours, or a URL mentioning it, is not this
    # registration and must not be reported as one.
    test "does not match a different server that merely mentions the name" do
      refute MCP.registered?("codrift-staging: http://localhost:1/mcp/sse - connected\n")
      refute MCP.registered?("notes: https://example.com/codrift: - connected\n")
    end
  end
end

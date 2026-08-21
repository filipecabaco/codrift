defmodule Codrift.CLI.Utf8OutputTest do
  @moduledoc """
  Regression coverage for the CLI's output encoding.

  The BEAM takes its standard-io encoding from the caller's locale, and with
  `LANG` and `LC_ALL` unset it settles on latin1. Writing a UTF-8 binary to a
  latin1 device corrupts every non-ASCII codepoint in two ways: above U+00FF
  into Erlang's literal `\\x{2014}` notation, which is not a legal JSON escape
  and so breaks every agent parsing `codrift memory ...`; and U+0080..U+00FF
  into a raw latin1 byte, which is not valid UTF-8 at all.

  This has to be an out-of-process test. The bug lives in the io device the VM
  chose at boot, so a test that writes and reads inside a VM the test runner
  started under a UTF-8 locale — or through `ExUnit.CaptureIO`, whose StringIO
  has its own encoding — passes while the bug is live. Every test here spawns
  a fresh `mix run` with the locale explicitly stripped and asserts on the
  bytes that come back.

  `boots latin1` is the guard on all of that: it pins that the spawned VM
  really did land on latin1, so a green suite means the fix worked rather than
  that the environment never reproduced the bug.
  """
  # Deliberately NOT async: every test here boots a whole extra BEAM, so this is
  # a heavy neighbour to put in the async pool. Running in the sync phase costs
  # a couple of seconds and keeps those boots off the rest of the suite.
  use ExUnit.Case, async: false

  # One constant per corruption mode: U+2014 comes back as `\x{2014}`, U+00E9 as
  # a bare 0xE9 byte. Written as codepoints rather than literals so this file
  # stays ASCII, which is fitting for a suite about encoding.
  #
  # These are for ASSERTING ON OUTPUT ONLY. Nothing non-ASCII may travel to a
  # subprocess as argv: when the parent VM has a latin1 native name encoding —
  # which is any Linux with no locale set, including CI — `System.cmd/3`
  # re-encodes each byte of a UTF-8 binary as its own latin1 character, so an em
  # dash arrives as the six mojibake bytes C3 A2 C2 80 C2 94 and the assertion
  # fails against a corruption the fix was never responsible for. macOS hides
  # this: it forces a utf8 name encoding whatever the locale, so a test that
  # passes non-ASCII through argv is green locally and red on CI. Build the
  # string inside the subprocess from codepoints instead, as the tests below do.
  @em_dash <<0x2014::utf8>>
  @e_acute <<0xE9::utf8>>

  @initiative "utf8-output-test"

  setup do
    # Every subprocess gets its own TMPDIR. `config/runtime.exs` rm_rf's
    # `$TMPDIR/codrift-test-home` on any `MIX_ENV=test` boot, so without this a
    # subprocess would delete the sandbox the parent suite is running out of —
    # and it also sandboxes the memory DB seeded below, for free.
    dir = Path.join(System.tmp_dir!(), "codrift-utf8-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, tmpdir: dir}
  end

  describe "the spawned VM reproduces the bug" do
    # Without this, every other test in the file could be passing for the wrong
    # reason. It also doubles as the proof that the corruption is real and that
    # `Codrift.CLI.Main.run/1` is what prevents it: the same write, through the
    # command module directly, still comes back mangled.
    test "boots latin1, and corrupts output when Main.run/1 is bypassed", ctx do
      {out, 0} =
        run_cli(ctx, """
        IO.puts("ENCODING=" <> inspect(:io.getopts(:standard_io)[:encoding]))
        #{seed_memory()}
        Codrift.CLI.Memory.run(["list", "#{@initiative}", "note"])
        """)

      assert out =~ "ENCODING=:latin1",
             "expected the spawned VM to fall back to latin1 with no locale set, got: " <>
               "#{inspect(out)}. Without that this suite cannot reproduce the bug."

      assert out =~ "\\x{2014}"
      refute String.valid?(out)
    end
  end

  describe "with Codrift.CLI.Main.run/1" do
    test "JSON on stdout is valid UTF-8 and parses", ctx do
      {out, 0} =
        run_cli(ctx, """
        #{seed_memory()}
        Codrift.CLI.Main.run(["memory", "list", "#{@initiative}", "note"])
        """)

      assert String.valid?(out), "output is not valid UTF-8: #{inspect(out)}"
      refute out =~ "x{", "output still contains an Erlang codepoint escape: #{out}"

      assert [%{"content" => content}] = JSON.decode!(String.trim(out))
      assert content == "em dash #{@em_dash} caf#{@e_acute}"
    end

    test "the usage banner is not mangled", ctx do
      {out, 0} = run_cli(ctx, ~s|Codrift.CLI.Main.run([])|)

      assert String.valid?(out)
      refute out =~ "x{"
      assert out =~ "primary interface #{@em_dash} run"
    end

    # `fail/1` writes JSON to stderr and halts non-zero, so it is a second
    # device with a second encoding, and the exit status is part of the
    # contract an agent reads.
    test "JSON on stderr is not mangled either", ctx do
      {out, 1} =
        run_cli(
          ctx,
          """
          bogus = "bogus" <> <<0x2014::utf8>>
          Codrift.CLI.Main.run(["memory", "add", "#{@initiative}", bogus, "x"])
          """,
          stderr_to_stdout: true
        )

      assert String.valid?(out)
      refute out =~ "x{"
      assert out =~ ~s|invalid type 'bogus#{@em_dash}'|
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # `--no-start` keeps the subprocess from booting the web server onto the port
  # the developer's app is already using; `--no-compile` keeps it from taking
  # the build lock the parent `mix test` still holds.
  defp run_cli(ctx, code, opts \\ []) do
    System.cmd(
      System.find_executable("mix"),
      ["run", "--no-start", "--no-compile", "-e", code],
      env: [
        {"MIX_ENV", "test"},
        {"TMPDIR", ctx.tmpdir},
        # A whole BEAM per test is a lot of machine to take for one line of
        # output, and by default it starts one scheduler per core. One is plenty
        # for `IO.puts`. Nothing under test depends on the child's own VM flags:
        # the io encoding comes from the locale, and the argv encoding from the
        # parent.
        {"ELIXIR_ERL_OPTIONS", "+S 1:1 +SDio 1"},
        {"LANG", nil},
        {"LC_ALL", nil},
        {"LC_CTYPE", nil}
      ],
      stderr_to_stdout: Keyword.get(opts, :stderr_to_stdout, false)
    )
  end

  # One entry holding both corruption modes. The data dir needs no override —
  # `config/runtime.exs` already points it under the private TMPDIR above.
  defp seed_memory do
    """
    File.mkdir_p!(Codrift.Paths.initiative_dir("#{@initiative}"))
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = Codrift.Memory.add(
      "#{@initiative}", "note",
      "em dash " <> <<0x2014::utf8>> <> " caf" <> <<0xE9::utf8>>, "test")
    """
  end
end

defmodule Codrift.OAuthTest do
  @moduledoc """
  Token-store guarantees for `Codrift.OAuth`.

  Access tokens are the most sensitive thing Codrift puts on disk, so the store
  is asserted on directly rather than inferred from the connect flow.

  **What these tests do and do not cover.** They pin the *end state*: mode 0600,
  no leftover temp file, parsable JSON. They do **not** prove the two properties
  the write path was actually changed for —

  - that token bytes never touch disk under the umask default (the temp file is
    chmod'ed 0600 while still empty), and
  - that a crash mid-write cannot truncate the store (`File.rename!` is atomic;
    `load_tokens/0` treats unparsable JSON as "no tokens", so a torn write would
    silently log every service out).

  Both hold by construction and neither is observable from the finished file —
  the previous implementation wrote then chmod'ed, and would still pass every
  assertion below. Read `save_tokens/1` to check them, not this file.

  `revoke_token/1` is the driver because it runs the same private write path as
  a completed OAuth flow, without needing a real provider.

  Persistence is redirected to a sandbox by `config/runtime.exs`, so nothing here
  touches the developer's real `~/.codrift/oauth_tokens.json`.
  """
  use ExUnit.Case, async: false

  alias Codrift.OAuth

  defp token_file, do: Path.join(Codrift.Paths.data_dir(), "oauth_tokens.json")

  setup do
    on_exit(fn -> File.rm(token_file()) end)
    :ok
  end

  test "the finished token store is mode 0600" do
    :ok = OAuth.revoke_token("github")

    assert File.exists?(token_file())
    {:ok, %File.Stat{mode: mode}} = File.stat(token_file())

    # Low 9 bits are the permission bits; 0o600 = owner rw, nothing for group/other.
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "writing leaves no temp file behind" do
    :ok = OAuth.revoke_token("github")

    refute File.exists?(token_file() <> ".tmp")
  end

  test "the store is parsable JSON after repeated writes" do
    for service <- ["github", "linear", "gitlab"], do: :ok = OAuth.revoke_token(service)

    assert {:ok, decoded} = token_file() |> File.read!() |> JSON.decode()
    assert is_map(decoded)
  end

  test "an unwritten store reads as no tokens rather than raising" do
    File.rm(token_file())

    assert OAuth.list_tokens() == %{}
    assert OAuth.get_token("github") == {:error, :not_found}
    refute OAuth.connected?("github")
  end
end

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
    assert OAuth.access_token("github") == {:error, :not_found}
    assert OAuth.status("github") == %{connected: false, needs_reauth: false}
  end

  describe "token lifetime" do
    # Linear hands out 24-hour access tokens and offers no way to ask for longer,
    # so "is this token still good, and can I renew it without the user" is a
    # question `access_token/1` has to answer on every single call. The refresh
    # *request* needs a live provider and is not exercised here; what is pinned is
    # the decision made before it — which is what used to be missing entirely, and
    # what turned a working Linear connection into a 401 the next morning.
    #

    defp write_token(service, token) do
      path = token_file()
      path |> Path.dirname() |> File.mkdir_p!()

      existing =
        case File.read(path) do
          {:ok, content} -> JSON.decode!(content)
          _ -> %{}
        end

      File.write!(path, JSON.encode!(Map.put(existing, service, token)))
    end

    defp in_seconds(offset), do: System.os_time(:second) + offset

    test "a token with time left is handed back untouched" do
      write_token("linear", %{"access_token" => "still-good", "expires_at" => in_seconds(3600)})

      assert OAuth.access_token("linear") == {:ok, "still-good"}
      assert %{connected: true, needs_reauth: false} = OAuth.status("linear")
    end

    test "a token with no expiry recorded never goes stale" do
      # GitHub's device-flow tokens genuinely do not expire, and tokens written
      # before `expires_at` existed have no deadline to compare against —
      # treating either as spent would sign the user out for nothing.
      write_token("github", %{"access_token" => "eternal"})

      assert OAuth.access_token("github") == {:ok, "eternal"}
      assert %{connected: true, needs_reauth: false} = OAuth.status("github")
    end

    test "an expired token with nothing to renew it asks for a reconnect" do
      write_token("linear", %{"access_token" => "stale", "expires_at" => in_seconds(-60)})

      assert OAuth.access_token("linear") == {:error, :reauth_required}
      assert %{connected: true, needs_reauth: true} = OAuth.status("linear")
    end

    test "an expired but refreshable token is not reported as needing a reconnect" do
      # It is about to renew itself on the next call; telling the user to go and
      # re-authorise would be advice to do work the app is already doing.
      write_token("linear", %{
        "access_token" => "stale",
        "refresh_token" => "renewable",
        "expires_at" => in_seconds(-60)
      })

      assert %{connected: true, needs_reauth: false} = OAuth.status("linear")
    end

    test "a token inside the refresh skew is treated as already expired" do
      # Expiring in 30s would survive the freshness check but not necessarily the
      # request that follows it, so the skew window has to renew early.
      write_token("linear", %{"access_token" => "expiring", "expires_at" => in_seconds(30)})

      assert OAuth.access_token("linear") == {:error, :reauth_required}
    end

    test "refresh/1 on a service that was never connected says so" do
      File.rm(token_file())

      assert OAuth.refresh("linear") == {:error, :not_found}
    end
  end
end

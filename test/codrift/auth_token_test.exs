defmodule Codrift.AuthTokenTest do
  @moduledoc false
  # Not async: fetch/0 caches in :persistent_term shared across the VM.
  use ExUnit.Case, async: false

  alias Codrift.AuthToken

  test "fetch/0 returns a stable token persisted with 0600 permissions" do
    token = AuthToken.fetch()

    assert String.length(token) >= 32
    assert AuthToken.fetch() == token

    assert File.read!(AuthToken.path()) |> String.trim() == token
    assert {:ok, %{mode: mode}} = File.stat(AuthToken.path())
    assert Bitwise.band(mode, 0o777) == 0o600
  end
end

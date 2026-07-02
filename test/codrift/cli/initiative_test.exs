defmodule Codrift.CLI.InitiativeTest do
  @moduledoc """
  Smoke coverage for the standalone CLI (release `eval` entrypoint), which
  reads/writes `initiatives.json` directly rather than through the Store
  GenServer. Chiefly guards that the CLI resolves its paths through
  `Codrift.Paths` — so it honours the test sandbox instead of the user's real
  `~/.config/codrift`.

  Not `async`: the CLI touches the same global on-disk files as the rest of the
  app under the shared sandbox home.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Codrift.CLI.Initiative, as: CLI
  alias Codrift.Paths

  defp run_json(argv) do
    argv |> capture_json() |> Jason.decode!()
  end

  defp capture_json(argv), do: capture_io(fn -> CLI.run(argv) end)

  test "list reads from the sandboxed config dir and emits JSON" do
    out = run_json(["list"])
    assert %{"initiatives" => list} = out
    assert is_list(list)
  end

  test "create writes to the sandbox initiatives.json, not the real home" do
    name = "cli-e2e-#{System.unique_integer([:positive])}"
    created = run_json(["create", name])
    id = created["id"]
    assert created["name"] == name

    on_exit(fn -> capture_io(fn -> CLI.run(["delete", id]) end) end)

    # The write landed in the sandbox file (proves Codrift.Paths routing).
    sandbox_file = Path.join(Paths.config_dir(), "initiatives.json")
    assert File.read!(sandbox_file) =~ id

    # And a follow-up list surfaces it.
    ids = run_json(["list"])["initiatives"] |> Enum.map(& &1["id"])
    assert id in ids
  end
end

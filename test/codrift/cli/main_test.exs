defmodule Codrift.CLI.MainTest do
  @moduledoc """
  The dispatch table, and the one thing about it that cannot be checked by
  running it: whether the shipped `codrift` can reach a command at all.

  `Codrift.CLI.Main` is only half the route. The release's boot script is a
  shell `case`, and `mix.exs` patches one branch into it per entry in
  `@cli_commands`; a verb `Main` dispatches but that list omits falls straight
  through to the release's own dispatch, which has never heard of it. Every test
  in this repo would still pass — they all call `Main.run/1` directly — while the
  command did nothing for anyone who installed it. That is exactly what happened
  to `pane`, which was in `Main` and missing from `@cli_commands`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Codrift.CLI.Main

  @repo_root Path.expand("../../..", __DIR__)

  # `Main`'s dispatch clauses, read from source: the verbs it answers to.
  defp dispatched_verbs do
    @repo_root
    |> Path.join("lib/codrift/cli/main.ex")
    |> File.read!()
    |> then(&Regex.scan(~r/defp dispatch\(\["([a-z_]+)"/, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
  end

  # The verbs `mix.exs` patches into the release's boot script.
  defp boot_script_verbs do
    @repo_root
    |> Path.join("mix.exs")
    |> File.read!()
    |> then(&Regex.run(~r/@cli_commands ~w\(([^)]+)\)/, &1, capture: :all_but_first))
    |> hd()
    |> String.split()
  end

  test "every command Main dispatches is reachable from the shipped CLI" do
    missing = dispatched_verbs() -- boot_script_verbs()

    assert missing == [],
           "#{Enum.join(missing, ", ")} are dispatched by Codrift.CLI.Main but missing from " <>
             "@cli_commands in mix.exs, so the released `codrift` cannot reach them. " <>
             "Add them to that list."
  end

  test "the dispatcher answers to open" do
    assert "open" in dispatched_verbs()
    assert "open" in boot_script_verbs()
  end

  describe "usage" do
    test "lists open alongside the other commands" do
      output = capture_io(fn -> Main.run([]) end)

      assert output =~ "codrift open"
      assert output =~ "codrift pane"
    end
  end
end

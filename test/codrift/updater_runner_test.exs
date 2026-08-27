defmodule Codrift.UpdaterRunnerTest do
  @moduledoc """
  The in-app updater's contract, minus the network.

  What is worth pinning here is the handoff: an update lands *after* this process
  is gone, so the scripts that finish it have to wait for that, must never delete
  the live install before a replacement is in place, and must reopen the app.
  Get any of those wrong and the failure mode is a user with no Codrift.
  """
  use ExUnit.Case, async: true

  alias Codrift.Updater.Runner

  describe "status/0" do
    test "starts idle, with nothing to quit for" do
      assert %{"stage" => "idle", "quit_required" => false, "log" => [], "error" => nil} =
               Runner.status()
    end
  end

  describe "start/2" do
    # The test suite runs with no CODRIFT_APP_PATH, which is the same shape as
    # `mix ex_tauri.dev` — nothing knows where the app is, so nothing is
    # replaced. A guessed path here would be a self-update writing over the
    # wrong tree.
    test "refuses when the shell never named an app to replace" do
      assert {:error, message} = Runner.start("9.9.9", %{})
      assert message =~ "cannot update itself"
      assert %{"stage" => "idle"} = Runner.status()
    end
  end

  describe "swap_script/2" do
    @app "/Applications/Codrift.app"
    @staged "/Users/x/.codrift/update/Codrift.app"

    test "waits for this process to exit before touching anything" do
      script = Runner.swap_script(@app, @staged)
      [wait, move] = [~r/kill -0 #{System.pid()}/, ~r/mv '#{@app}'/]

      assert Regex.match?(wait, script)
      assert Regex.run(wait, script, return: :index) < Regex.run(move, script, return: :index)
    end

    test "renames the live bundle aside instead of deleting it" do
      script = Runner.swap_script(@app, @staged)

      assert script =~ "mv '#{@app}' '#{@app}.old'"
      # …and puts it back if the replacement cannot be moved into place.
      assert script =~ "|| { mv '#{@app}.old' '#{@app}'; exit 1; }"
    end

    test "reopens the app it just replaced" do
      assert Runner.swap_script(@app, @staged) =~ "open -n '#{@app}'"
    end

    # Paths come from the environment and from GitHub asset names. Neither is
    # ours, and both end up in a shell script.
    test "quotes a path containing a quote" do
      script = Runner.swap_script("/Applications/Bob's.app", @staged)
      assert script =~ ~S('/Applications/Bob'\'')
    end
  end

  describe "brew_script/2" do
    test "upgrades and then reopens, after waiting for this process to exit" do
      script = Runner.brew_script("/opt/homebrew/bin/brew", "/Applications/Codrift.app")

      assert script =~ "kill -0 #{System.pid()}"
      assert script =~ "'/opt/homebrew/bin/brew' upgrade codrift"
      assert script =~ "open -n '/Applications/Codrift.app'"
    end

    test "records what brew did, since the app is not around to read it" do
      script = Runner.brew_script("/opt/homebrew/bin/brew", "/Applications/Codrift.app")
      assert script =~ "brew exited with"
    end
  end
end

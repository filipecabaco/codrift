defmodule Codrift.CLI.IntegrationCLITest do
  @moduledoc """
  `codrift integration` — the subcommands that answer without a network call.

  This command is how an agent finds out whether a tracker is usable *before*
  trying to import from it, so `services` is the one that has to be right: it
  reports a per-service connected flag and auth type, and a service that goes
  missing from that list becomes an integration nobody can discover.

  `auth`, `import`, `list`, `assigned` and `sync` all either reach the network
  or end in `fail/1` → `System.halt/1`, which would take the test VM with it.
  The other CLI suites draw the same line.

  Not `async`: reads the sandboxed data directory for stored tokens.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Codrift.CLI.Integration, as: CLI
  alias Codrift.Integration

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:codrift, :data_dir)
    Application.put_env(:codrift, :data_dir, tmp_dir)
    on_exit(fn -> Application.put_env(:codrift, :data_dir, previous) end)
    :ok
  end

  defp run_json(argv) do
    capture_io(fn -> CLI.run(argv) end) |> String.trim() |> JSON.decode!()
  end

  describe "services" do
    test "reports every registered adapter" do
      names = run_json(["services"]) |> Enum.map(& &1["name"])

      assert Enum.sort(names) == Enum.sort(Integration.valid_services())
    end

    test "each entry carries a connected flag and an auth type" do
      for service <- run_json(["services"]) do
        assert is_boolean(service["connected"]), "#{service["name"]} has no connected flag"
        assert is_binary(service["auth"]), "#{service["name"]} has no auth type"
      end
    end

    test "with no tokens stored, nothing claims to be connected" do
      assert Enum.all?(run_json(["services"]), &(&1["connected"] == false))
    end

    test "the auth type matches the flow the OAuth config declares" do
      by_name = Map.new(run_json(["services"]), &{&1["name"], &1["auth"]})

      for service <- Codrift.OAuth.Config.pkce_services(), Map.has_key?(by_name, service) do
        assert by_name[service] =~ "pkce" or by_name[service] =~ "browser",
               "#{service} should report a browser flow, got #{by_name[service]}"
      end

      for service <- Codrift.OAuth.Config.device_flow_services(),
          Map.has_key?(by_name, service) do
        assert by_name[service] =~ "device",
               "#{service} should report a device flow, got #{by_name[service]}"
      end
    end
  end

  describe "tokens" do
    test "with none stored, reports an empty set rather than failing" do
      assert run_json(["tokens"]) in [[], %{}]
    end
  end

  describe "revoke" do
    test "revoking a service that was never connected is not an error" do
      # Idempotent on purpose: an agent cleaning up should not have to check
      # first, and a failure here would look like the token is still live.
      assert %{"revoked" => "linear"} == run_json(["revoke", "linear"])
    end
  end

  describe "usage" do
    test "lists every subcommand" do
      output = capture_io(fn -> CLI.run(["nonsense"]) end)

      for command <- ~w[services auth tokens revoke list assigned import sync] do
        assert output =~ "codrift integration #{command}", "usage omitted #{command}"
      end
    end

    test "names every service, so the reader knows what to pass" do
      output = capture_io(fn -> CLI.run([]) end)

      for service <- Integration.valid_services() do
        assert output =~ service, "usage omitted #{service}"
      end
    end

    test "explains both auth flows, since one of them needs the desktop app" do
      output = capture_io(fn -> CLI.run([]) end)

      assert output =~ "PKCE"
      assert output =~ "Device flow"
      assert output =~ "desktop app"
    end
  end
end

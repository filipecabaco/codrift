defmodule Codrift.Web.ConductorE2ETest do
  @moduledoc """
  End-to-end coverage of the Conductor / orchestration surface — the headline
  "one agent orchestrating sub-agents" feature — driven through the real
  `POST /api/rpc` → `Codrift.Core` seam against the live global
  ConductorSupervisor and AgentSupervisor.

  The supervisor-level unit tests (`conductor_supervisor_test.exs`) cover the
  process mechanics with a stub adapter; this covers the Core wiring and
  response shaping, and drives a real fan-out/orchestrator agent with the
  `terminal` adapter (a PTY shell).

  Not `async`: shares the application's global conductor/agent supervisors.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Codrift.{AgentSupervisor, ConductorSupervisor}
  alias Codrift.Initiative.Store

  @opts Codrift.init([])

  defp rpc(name, args) do
    conn =
      conn(:post, "/api/rpc", Jason.encode!(%{"name" => name, "args" => args}))
      |> put_req_header("content-type", "application/json")
      |> Codrift.call(@opts)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp ok!(name, args) do
    assert {200, %{"ok" => result}} = rpc(name, args)
    result
  end

  defp create_initiative!(dirs) do
    id =
      ok!("create_initiative", %{
        "name" => "cond-#{System.unique_integer([:positive])}",
        "dirs" => dirs
      })["id"]

    on_exit(fn -> rpc("delete_initiative", %{"initiative_id" => id}) end)
    id
  end

  # Sub-agents are :temporary on the global supervisor, so they outlive the
  # conductor — stop it via the Core op and sweep what it left behind.
  defp stop_conductor_and_agents(id) do
    on_exit(fn ->
      rpc("stop_orchestration", %{"initiative_id" => id})

      id
      |> AgentSupervisor.list_agents_for_initiative()
      |> Enum.each(&AgentSupervisor.stop_agent/1)
    end)
  end

  defp eventually(fun, attempts \\ 80, sleep_ms \\ 50) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case fun.() do
        nil -> :timer.sleep(sleep_ms) && {:cont, nil}
        false -> :timer.sleep(sleep_ms) && {:cont, nil}
        val -> {:halt, val}
      end
    end)
  end

  # ── Error paths (deterministic, no agents) ───────────────────────────────────

  describe "conductor error paths" do
    test "status/results error when no conductor is running" do
      id = create_initiative!([])
      assert {422, %{"error" => s}} = rpc("get_conductor_status", %{"initiative_id" => id})
      assert s =~ "no conductor running"
      assert {422, %{"error" => r}} = rpc("get_conductor_results", %{"initiative_id" => id})
      assert r =~ "no conductor running"
    end

    test "start_conductor / start_orchestration on unknown initiative report not-found" do
      assert {422, %{"error" => m1}} = rpc("start_conductor", %{"initiative_id" => "nope"})
      assert m1 =~ "not found"

      assert {422, %{"error" => m2}} =
               rpc("start_orchestration", %{"initiative_id" => "nope", "task" => "x"})

      assert m2 =~ "not found"
    end
  end

  # ── orchestration.md round trip (deterministic, no agents) ───────────────────

  describe "orchestration.md" do
    test "update then read round-trips through Core" do
      id = create_initiative!([])

      # Seeding happens in a handle_continue; read_orchestration_md/1 serialises
      # behind it, so a read straight after create sees the file.
      assert %{"content" => seeded} = ok!("read_orchestration_md", %{"initiative_id" => id})
      assert seeded =~ "Orchestrator"

      content = "# Plan\n\n- split work by service\n"

      assert %{"updated" => true} =
               ok!("update_orchestration_md", %{"initiative_id" => id, "content" => content})

      assert %{"content" => ^content} = ok!("read_orchestration_md", %{"initiative_id" => id})
    end
  end

  # ── Live fan-out conductor (terminal adapter) ────────────────────────────────

  describe "fan-out conductor" do
    @tag :tmp_dir
    test "start → status shows a worker per dir → results is a map → idempotent restart", %{
      tmp_dir: tmp_dir
    } do
      id = create_initiative!([tmp_dir])
      stop_conductor_and_agents(id)

      assert %{"started" => true, "initiative_id" => ^id} =
               ok!("start_conductor", %{"initiative_id" => id, "adapter" => "terminal"})

      # The agent is started asynchronously in a handle_continue — poll for it.
      agents =
        eventually(fn ->
          %{"agents" => a} = ok!("get_conductor_status", %{"initiative_id" => id})
          if map_size(a) > 0, do: a, else: nil
        end)

      assert map_size(agents) == 1
      assert [%{"role" => "worker", "dir" => ^tmp_dir}] = Map.values(agents)

      # Results are keyed per agent (may be empty until the shell emits).
      %{"results" => results} = ok!("get_conductor_results", %{"initiative_id" => id})
      assert is_map(results)

      # A second start is a no-op, not a duplicate conductor.
      assert %{"started" => false, "reason" => "already running"} =
               ok!("start_conductor", %{"initiative_id" => id, "adapter" => "terminal"})
    end
  end

  # ── Live orchestrator conductor (terminal adapter) ───────────────────────────

  describe "orchestrator conductor" do
    @tag :tmp_dir
    test "start_orchestration launches exactly one orchestrator agent", %{tmp_dir: tmp_dir} do
      id = create_initiative!([tmp_dir])
      stop_conductor_and_agents(id)

      assert %{"started" => true} =
               ok!("start_orchestration", %{
                 "initiative_id" => id,
                 "task" => "audit the codebase",
                 "adapter" => "terminal",
                 "context_dir" => tmp_dir
               })

      roles =
        eventually(fn ->
          %{"agents" => a} = ok!("get_conductor_status", %{"initiative_id" => id})
          if map_size(a) > 0, do: Enum.map(Map.values(a), & &1["role"]), else: nil
        end)

      assert roles == ["orchestrator"]
    end

    test "orchestrator defaults to the initiative's own context folder" do
      id = create_initiative!([])
      stop_conductor_and_agents(id)

      assert %{"started" => true} =
               ok!("start_orchestration", %{
                 "initiative_id" => id,
                 "task" => "plan the work",
                 "adapter" => "terminal"
               })

      # Without an explicit context_dir the orchestrator runs at the initiative
      # root, so it can edit orchestration.md and the shared context files.
      scratch = Store.context_path(id)

      dirs =
        eventually(fn ->
          %{"agents" => a} = ok!("get_conductor_status", %{"initiative_id" => id})
          if map_size(a) > 0, do: Enum.map(Map.values(a), & &1["dir"]), else: nil
        end)

      assert dirs == [scratch]
    end

    @tag :tmp_dir
    test "conductor captures output from the agent it started", %{tmp_dir: tmp_dir} do
      id = create_initiative!([tmp_dir])
      stop_conductor_and_agents(id)

      ok!("start_orchestration", %{
        "initiative_id" => id,
        "task" => "audit",
        "adapter" => "terminal",
        "context_dir" => tmp_dir
      })

      # Proves the whole loop is wired: conductor started an agent, subscribed to
      # it, and is accumulating its bytes. (That the prompt text carries the task
      # is asserted in conductor_test.exs with a controllable adapter — a real
      # shell echoes stdin back interleaved with line-editor escapes, so the task
      # string never survives intact here.)
      assert eventually(fn ->
               %{"results" => results} = ok!("get_conductor_results", %{"initiative_id" => id})
               Enum.any?(Map.values(results), &(&1 != ""))
             end),
             "conductor captured no output from the orchestrator it started"
    end
  end

  # ── Teardown paths ───────────────────────────────────────────────────────────

  describe "stopping orchestration" do
    test "stop_orchestration tears the conductor down and is idempotent" do
      id = create_initiative!([])
      stop_conductor_and_agents(id)

      ok!("start_orchestration", %{
        "initiative_id" => id,
        "task" => "work to stop",
        "adapter" => "terminal"
      })

      assert %{"stopped" => true} = ok!("stop_orchestration", %{"initiative_id" => id})

      # Status is unavailable once the conductor is gone.
      assert {422, %{"error" => msg}} = rpc("get_conductor_status", %{"initiative_id" => id})
      assert msg =~ "no conductor running"

      # Stopping again reports "nothing was running" rather than erroring.
      assert %{"stopped" => false} = ok!("stop_orchestration", %{"initiative_id" => id})
    end

    # A lookup can hand back a pid that has already died.
    # stop_conductor/2 and delete_initiative both run through the same window:
    # the registry can hand back a pid that is already gone.
    test "stopping a conductor that died between lookup and terminate still succeeds" do
      id = create_initiative!([])
      stop_conductor_and_agents(id)

      ok!("start_orchestration", %{
        "initiative_id" => id,
        "task" => "about to vanish",
        "adapter" => "terminal"
      })

      {:ok, pid} = ConductorSupervisor.find_conductor(id)
      Process.exit(pid, :kill)

      assert %{"stopped" => _} = ok!("stop_orchestration", %{"initiative_id" => id})
      assert %{"deleted" => ^id} = ok!("delete_initiative", %{"initiative_id" => id})
    end

    test "status and results survive a conductor that died between lookup and call" do
      id = create_initiative!([])
      stop_conductor_and_agents(id)

      ok!("start_orchestration", %{
        "initiative_id" => id,
        "task" => "about to die",
        "adapter" => "terminal"
      })

      {:ok, pid} = ConductorSupervisor.find_conductor(id)

      # Kill it outside the supervisor, so the registry entry is briefly stale.
      Process.exit(pid, :kill)

      for op <- ["get_conductor_status", "get_conductor_results"] do
        assert {status, body} = rpc(op, %{"initiative_id" => id})
        assert status == 422, "#{op} returned #{status}: #{inspect(body)}"
        assert body["error"] =~ "no conductor running"
      end
    end

    test "deleting an initiative stops its orchestration" do
      id = create_initiative!([])
      stop_conductor_and_agents(id)

      ok!("start_orchestration", %{
        "initiative_id" => id,
        "task" => "work that must not outlive its initiative",
        "adapter" => "terminal"
      })

      assert eventually(fn ->
               match?({200, _}, rpc("get_conductor_status", %{"initiative_id" => id}))
             end)

      assert %{"deleted" => ^id} = ok!("delete_initiative", %{"initiative_id" => id})

      # Registry entries clear on the DOWN message, so this lags terminate_child.
      assert eventually(fn ->
               match?({:error, :not_found}, ConductorSupervisor.find_conductor(id))
             end),
             "conductor was still registered after its initiative was deleted"
    end
  end
end

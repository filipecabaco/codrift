defmodule Codrift.CoreHandoffTest do
  @moduledoc """
  Coverage for the two operations that hand control back to the person at the
  keyboard: `open_terminal` and `focus_agent`.

  These are the only tools an agent has for a step it is not allowed to take —
  a commit the user reserves for themselves, a credential prompt — so the
  contract that matters is that the drafted command is *typed and not run*, and
  that the window is actually told to surface the pane. Both are asserted here.

  Not `async`: registers in the global `Codrift.AgentWatchers` registry and
  starts agents under the global supervisor, neither of which is per-test.
  """
  use ExUnit.Case, async: false

  alias Codrift.AgentProcess
  alias Codrift.AgentSupervisor
  alias Codrift.Core
  alias Codrift.Initiative.Store
  alias Codrift.Test.EchoAdapter

  setup do
    {:ok, initiative} = Core.call("create_initiative", %{"name" => "handoff-test"})
    id = initiative["id"]

    # Watchers are how a connected window hears about any of this; standing in
    # for one is the only way to observe the request half of the contract.
    Registry.register(Codrift.AgentWatchers, :all, nil)

    on_exit(fn ->
      for pid <- AgentSupervisor.list_agents_for_initiative(id) do
        AgentSupervisor.stop_agent(pid)
      end

      Core.call("delete_initiative", %{"initiative_id" => id})
    end)

    {:ok, initiative_id: id}
  end

  describe "open_terminal" do
    test "starts a shell bound to the initiative", %{initiative_id: id} do
      assert {:ok, agent} = Core.call("open_terminal", %{"initiative_id" => id})

      assert agent.adapter == "terminal"
      assert agent.initiative_id == id
      assert agent.awaiting_user == true
      assert {:ok, _pid} = AgentSupervisor.find_agent(agent.id)
    end

    test "falls back to the initiative's own folder when no dir is given", %{initiative_id: id} do
      {:ok, agent} = Core.call("open_terminal", %{"initiative_id" => id})

      assert agent.dir == Store.context_path(id)
    end

    test "runs in an explicit dir when one is given", %{initiative_id: id} do
      dir = System.tmp_dir!()

      {:ok, agent} = Core.call("open_terminal", %{"initiative_id" => id, "dir" => dir})

      assert agent.dir == Path.expand(dir)
    end

    # The point of the whole tool. `send_input/2` appends CRLF and would run the
    # command; the prefill goes through `send_raw/2` so it sits at the prompt for
    # the user to read and submit themselves.
    test "reports the command it typed at the prompt", %{initiative_id: id} do
      {:ok, agent} =
        Core.call("open_terminal", %{
          "initiative_id" => id,
          "command" => ~s(git commit -m "add rotation")
        })

      assert agent.prefilled == ~s(git commit -m "add rotation")
    end

    # A newline inside the command would submit every line before it, turning a
    # draft into an execution — which is exactly the thing the user withheld
    # permission for. Flattened to spaces so nothing can submit itself.
    test "flattens newlines so a prefill cannot execute itself", %{initiative_id: id} do
      {:ok, agent} =
        Core.call("open_terminal", %{
          "initiative_id" => id,
          "command" => "git commit -m \"x\"\nrm -rf /tmp/nope\r\necho done"
        })

      refute String.contains?(agent.prefilled, "\n")
      refute String.contains?(agent.prefilled, "\r")
      assert agent.prefilled == ~s(git commit -m "x" rm -rf /tmp/nope echo done)
    end

    test "types nothing when no command is given", %{initiative_id: id} do
      {:ok, agent} = Core.call("open_terminal", %{"initiative_id" => id})
      assert agent.prefilled == nil

      {:ok, blank} = Core.call("open_terminal", %{"initiative_id" => id, "command" => "   "})
      assert blank.prefilled == nil
    end

    test "asks the window to surface the pane, with the reason", %{initiative_id: id} do
      {:ok, agent} =
        Core.call("open_terminal", %{"initiative_id" => id, "reason" => "review and commit"})

      agent_id = agent.id

      assert_receive {:pane_request, ^id, ^agent_id, "review and commit"}, 2_000
    end

    # The window binds the request to an agent it already knows about, so the
    # announcement has to come first. Both ride the same relay mailbox, so the
    # order they are sent in is the order a window sees.
    test "announces the agent before requesting a pane for it", %{initiative_id: id} do
      {:ok, agent} = Core.call("open_terminal", %{"initiative_id" => id})
      agent_id = agent.id

      assert_receive {:agent_started, %{id: ^agent_id}}, 2_000
      assert_receive {:pane_request, ^id, ^agent_id, _}, 2_000
    end

    test "reports an unknown initiative rather than starting a stray shell" do
      assert {:error, _} = Core.call("open_terminal", %{"initiative_id" => "no-such-initiative"})
    end
  end

  describe "focus_agent" do
    test "requests a pane for an already-running agent", %{initiative_id: id} do
      pid =
        start_supervised!(
          {AgentProcess,
           [
             id: "focus-#{System.unique_integer([:positive])}",
             initiative_id: id,
             dir: System.tmp_dir!(),
             adapter: EchoAdapter
           ]}
        )

      %{id: agent_id} = AgentProcess.status(pid)

      assert {:ok, %{"focused" => ^agent_id}} =
               Core.call("focus_agent", %{"agent_id" => agent_id, "reason" => "back to you"})

      assert_receive {:pane_request, ^id, ^agent_id, "back to you"}, 2_000
    end

    test "carries a nil reason rather than refusing", %{initiative_id: id} do
      pid =
        start_supervised!(
          {AgentProcess,
           [
             id: "focus-noreason-#{System.unique_integer([:positive])}",
             initiative_id: id,
             dir: System.tmp_dir!(),
             adapter: EchoAdapter
           ]}
        )

      %{id: agent_id} = AgentProcess.status(pid)

      assert {:ok, _} = Core.call("focus_agent", %{"agent_id" => agent_id})
      assert_receive {:pane_request, ^id, ^agent_id, nil}, 2_000
    end

    test "reports an agent that is not running" do
      assert {:error, message} = Core.call("focus_agent", %{"agent_id" => "not-a-real-agent"})
      assert message =~ "not-a-real-agent"
    end
  end
end

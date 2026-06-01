defmodule Codrift.AgentProcessTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.AgentProcess
  alias Codrift.Test.EchoAdapter

  defp start_agent(opts \\ []) do
    id = Keyword.get(opts, :id, "test-#{:erlang.unique_integer([:positive])}")
    dir = Keyword.get(opts, :dir, System.tmp_dir!())
    adapter = Keyword.get(opts, :adapter, EchoAdapter)

    start_supervised!(
      {AgentProcess, [id: id, initiative_id: "test-init", dir: dir, adapter: adapter]}
    )
  end

  test "starts with :starting status" do
    pid = start_agent()
    assert %{status: :starting} = AgentProcess.status(pid)
  end

  test "status includes id, initiative_id, dir, and adapter" do
    dir = System.tmp_dir!()
    pid = start_agent(id: "my-id", dir: dir)

    assert %{
             id: "my-id",
             initiative_id: "test-init",
             dir: ^dir,
             adapter: EchoAdapter,
             status: :starting
           } = AgentProcess.status(pid)
  end

  test "subscribe delivers output notifications to caller" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    AgentProcess.send_input(pid, "ping")

    assert_receive {:agent_output, _id, data}, 1_000
    assert String.contains?(data, "ping")
  end

  test "receives output from the process and buffers it" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    AgentProcess.send_input(pid, "hello from test")
    assert_receive {:agent_output, _id, _data}, 1_000

    refute Enum.empty?(AgentProcess.recent_output(pid))
  end

  test "recent_output returns lines in chronological order" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    AgentProcess.send_input(pid, "alpha")
    assert_receive {:agent_output, _, _}, 500

    AgentProcess.send_input(pid, "beta")
    assert_receive {:agent_output, _, _}, 500

    joined = pid |> AgentProcess.recent_output() |> Enum.join()

    assert String.contains?(joined, "alpha")
    assert String.contains?(joined, "beta")

    {alpha_pos, _} = :binary.match(joined, "alpha")
    {beta_pos, _} = :binary.match(joined, "beta")
    assert alpha_pos < beta_pos, "expected 'alpha' before 'beta' in output"
  end

  test "parse_status updates status on matching output" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    AgentProcess.send_input(pid, "READY")
    assert_receive {:agent_output, _, _}, 500

    assert %{status: :awaiting_input} = AgentProcess.status(pid)
  end

  test "subscriber is cleaned up when it exits" do
    pid = start_agent()

    subscriber = spawn(fn -> receive do: (_ -> :ok) end)
    :ok = AgentProcess.subscribe(pid, subscriber)
    Process.exit(subscriber, :kill)

    :timer.sleep(50)

    assert Process.alive?(pid)
    assert %{status: _} = AgentProcess.status(pid)
  end

  test "send_input is a no-op when agent is stopped" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    :sys.replace_state(pid, &%{&1 | status: :stopped})

    AgentProcess.send_input(pid, "should be ignored")

    refute_receive {:agent_output, _, _}, 100
    assert Process.alive?(pid)
  end

  test "buffer is capped at 1000 entries" do
    pid = start_agent()
    :ok = AgentProcess.subscribe(pid)

    for i <- 1..120 do
      AgentProcess.send_input(pid, "line #{i}")
      assert_receive {:agent_output, _, _}, 500
    end

    output = AgentProcess.recent_output(pid, 2_000)
    assert length(output) <= 1_000
    assert output != []
  end
end

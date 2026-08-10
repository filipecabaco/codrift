defmodule Codrift.Web.HealthTest do
  @moduledoc """
  `/api/health` is the Tauri shell's startup handshake, not just a liveness ping:
  it echoes CODRIFT_INSTANCE_TOKEN so the shell can tell the sidecar it spawned
  apart from any other Codrift already holding :43117. Dropping the field would
  silently reintroduce the shell adopting a stale backend.

  Not `async`: it mutates the process environment.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  @opts Codrift.init([])

  setup do
    prev = System.get_env("CODRIFT_INSTANCE_TOKEN")

    on_exit(fn ->
      if prev,
        do: System.put_env("CODRIFT_INSTANCE_TOKEN", prev),
        else: System.delete_env("CODRIFT_INSTANCE_TOKEN")
    end)

    :ok
  end

  defp health do
    conn(:get, "http://localhost/api/health")
    |> Codrift.call(@opts)
    |> then(& &1.resp_body)
    |> Jason.decode!()
  end

  test "echoes the instance token the shell launched this sidecar with" do
    System.put_env("CODRIFT_INSTANCE_TOKEN", "abc-123")
    assert %{"ok" => true, "instance" => "abc-123"} = health()
  end

  test "reports an empty instance when launched without a token" do
    System.delete_env("CODRIFT_INSTANCE_TOKEN")
    assert %{"ok" => true, "instance" => ""} = health()
  end
end

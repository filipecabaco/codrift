defmodule Codrift.AgentLogs do
  @moduledoc """
  Read access to the append-only agent transcript logs that
  `Codrift.AgentProcess` writes under `<context>/.agent-logs/<agent_id>.log`.

  The in-memory output buffer dies with the agent process; these logs are the
  durable record. They let the API serve scrollback for agents that are no
  longer running (after a crash, a stop, or a Codrift restart).
  """

  @tail_bytes 262_144

  @doc """
  Returns `{:ok, data}` with the last `max_bytes` (default 256 KiB) of the
  agent's transcript, searching every initiative's `.agent-logs` folder.

  Returns `{:error, :not_found}` when no log exists or the id is not a plain
  agent id (path separators and traversal are rejected).
  """
  @spec tail(String.t(), pos_integer()) :: {:ok, binary()} | {:error, :not_found}
  def tail(agent_id, max_bytes \\ @tail_bytes) do
    with true <- valid_id?(agent_id),
         [path | _] <- find_logs(agent_id) do
      read_tail(path, max_bytes)
    else
      _ -> {:error, :not_found}
    end
  end

  defp valid_id?(agent_id) when is_binary(agent_id), do: agent_id =~ ~r/^[A-Za-z0-9_-]+$/
  defp valid_id?(_), do: false

  defp find_logs(agent_id) do
    # match_dot: the .agent-logs path component starts with a dot, which
    # wildcards skip by default.
    [Codrift.Paths.initiatives_base(), "*", ".agent-logs", agent_id <> ".log"]
    |> Path.join()
    |> Path.wildcard(match_dot: true)
  end

  defp read_tail(path, max_bytes) do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, fd} <- :file.open(path, [:read, :raw, :binary]) do
      offset = max(size - max_bytes, 0)

      result =
        case :file.pread(fd, offset, max_bytes) do
          {:ok, data} -> {:ok, data}
          :eof -> {:ok, ""}
          {:error, _} -> {:error, :not_found}
        end

      :file.close(fd)
      result
    else
      _ -> {:error, :not_found}
    end
  end
end

defmodule Codrift.MCP.SSESession do
  @moduledoc """
  Correlates a legacy HTTP+SSE MCP session with the process holding its stream.

  The HTTP+SSE transport (MCP protocol 2024-11-05) splits one logical
  connection across two HTTP requests. The client opens `GET /mcp/sse` and the
  first event on that stream — `endpoint` — tells it where to POST. Every
  JSON-RPC *response* then has to travel back down the SSE stream; the POST
  itself is only acknowledged. So `POST /mcp`, which Bandit runs in a different
  process, needs a way to find the stream belonging to the same session.

  That is what this registry is for. `GET /mcp/sse` calls `open/0` to register
  its own pid under a fresh session id and hands the client
  `/mcp?sessionId=<id>`; `POST /mcp` looks the id back up and `deliver/2`s the
  response, which Francis surfaces to the SSE handler as `{:received, msg}`.

  Without this correlation the SSE transport cannot work at all: Codrift used to
  advertise a bare `/mcp` as the endpoint and answer in the POST body, so every
  SSE client posted `initialize` and then waited on a stream that would never
  carry a reply. The connection hung until the client's timeout — which is what
  "the Codrift MCP server is never available" looked like from the outside.

  `Registry` unregisters a key when its owning process exits, so a dropped
  stream cleans up after itself and a stale `sessionId` resolves to
  `{:error, :no_session}` rather than to somebody else's connection.
  """

  @registry Codrift.MCP.SessionRegistry

  @doc "Child spec for the supervision tree in `Codrift.start/2`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  @doc """
  Registers the calling process as the SSE stream for a fresh session id.

  Must be called from the process that owns the stream — `Registry` always
  registers its caller, and that is the process `deliver/2` needs to reach.
  """
  @spec open() :: String.t()
  def open do
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    {:ok, _pid} = Registry.register(@registry, id, nil)
    id
  end

  @doc """
  Hands `payload` to the SSE stream owned by `session_id`.

  Returns `{:error, :no_session}` when nothing holds that id — an expired or
  forged session, or a POST that arrived after its stream closed.
  """
  @spec deliver(String.t(), iodata()) :: :ok | {:error, :no_session}
  def deliver(session_id, payload) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _value}] ->
        send(pid, {:mcp_message, payload})
        :ok

      [] ->
        {:error, :no_session}
    end
  end
end

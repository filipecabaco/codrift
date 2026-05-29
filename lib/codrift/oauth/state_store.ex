defmodule Codrift.OAuth.StateStore do
  @moduledoc """
  In-memory store for in-flight PKCE OAuth2 state tokens.

  Each entry ties an opaque `state` string to the `{service, code_verifier}`
  pair generated when the flow started. The verifier must be sent at token
  exchange to prove the same party that started the flow is completing it
  (PKCE, RFC 7636).

  Entries are one-time-use and expire after 10 minutes. This is a supervised
  Agent — it only runs when the application supervision tree is active.
  """

  use Agent

  @expiry_seconds 600

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Stores a PKCE state entry: `state → {service, code_verifier, created_at}`."
  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(state, service, code_verifier) do
    Agent.update(__MODULE__, fn map ->
      map
      |> prune_expired()
      |> Map.put(state, {service, code_verifier, System.os_time(:second)})
    end)
  end

  @doc """
  Looks up, validates, and removes a state entry.

  Returns `{:ok, service, code_verifier}` when valid and unexpired.
  Returns `{:error, reason}` for unknown or expired states.
  """
  @spec pop(String.t()) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  def pop(state) do
    Agent.get_and_update(__MODULE__, fn map ->
      now = System.os_time(:second)

      case Map.get(map, state) do
        nil ->
          {{:error, "unknown or expired OAuth state"}, map}

        {_service, _verifier, created_at} when now - created_at > @expiry_seconds ->
          {{:error, "OAuth state expired — restart the authorization flow"},
           Map.delete(map, state)}

        {service, verifier, _created_at} ->
          {{:ok, service, verifier}, Map.delete(map, state)}
      end
    end)
  end

  defp prune_expired(map) do
    now = System.os_time(:second)
    Map.reject(map, fn {_state, {_service, _verifier, ts}} -> now - ts > @expiry_seconds end)
  end
end

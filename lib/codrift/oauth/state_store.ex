defmodule Codrift.OAuth.StateStore do
  @moduledoc """
  In-memory store for OAuth2 CSRF state tokens.

  Each `state` is a short-lived opaque token tied to a specific service.
  It is generated when the OAuth flow starts and consumed (one-time) when
  the callback arrives. States older than 10 minutes are expired.

  This is a supervised Agent — it only runs when the application supervision
  tree is active (i.e. when the TUI/web server is running).
  """

  use Agent

  @expiry_seconds 600

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Stores a state token tied to a service name."
  @spec put(String.t(), String.t()) :: :ok
  def put(state, service) do
    Agent.update(__MODULE__, fn map ->
      map
      |> prune_expired()
      |> Map.put(state, {service, System.os_time(:second)})
    end)
  end

  @doc """
  Looks up and removes a state token.

  Returns `{:ok, service}` if the state is valid and unexpired,
  or `{:error, reason}` otherwise.
  """
  @spec pop(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def pop(state) do
    Agent.get_and_update(__MODULE__, fn map ->
      now = System.os_time(:second)

      case Map.get(map, state) do
        nil ->
          {{:error, "unknown or expired OAuth state"}, map}

        {service, created_at} when now - created_at > @expiry_seconds ->
          {{:error, "OAuth state expired"}, Map.delete(map, state)}

        {service, _created_at} ->
          {{:ok, service}, Map.delete(map, state)}
      end
    end)
  end

  defp prune_expired(map) do
    now = System.os_time(:second)
    Map.reject(map, fn {_state, {_service, ts}} -> now - ts > @expiry_seconds end)
  end
end

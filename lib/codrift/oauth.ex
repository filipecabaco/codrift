defmodule Codrift.OAuth do
  @moduledoc """
  OAuth2 token management for Codrift external integrations.

  ## Token storage

  Tokens are stored in `~/.codrift/oauth_tokens.json` as a plain JSON object
  keyed by service name. The file is readable only by the current user (mode 0600).

  ## Flow

  1. Client calls `start_flow/1` to get an authorization URL (+ opaque state).
  2. User opens the URL in a browser and authorizes the Codrift OAuth app.
  3. The provider redirects to `http://localhost:7437/oauth/callback/{service}?code=...&state=...`.
  4. The web server calls `handle_callback/3` which verifies the state, exchanges the
     code for a token, and saves it.
  5. All subsequent API calls by the adapter use the stored token automatically.

  ## Precedence

  Adapters check tokens in this order:
  1. Stored OAuth token (`Codrift.OAuth.get_token/1`)
  2. Environment variable (legacy / CI usage)

  ## Revoking

  `revoke_token/1` removes the stored token. The adapter will then fall back to
  env vars or prompt the user to run `codrift integration auth <service>` again.
  """

  alias Codrift.OAuth.Config
  alias Codrift.OAuth.StateStore
  alias Codrift.Integration.HTTP

  @token_file "~/.codrift/oauth_tokens.json"

  @doc """
  Starts an OAuth2 flow for a service.

  Generates a CSRF state token, stores it in the StateStore, and returns the
  authorization URL for the user to open.

  Returns `{:error, reason}` when the service doesn't support OAuth, the client
  ID env var is missing, or the StateStore is not running.
  """
  @spec start_flow(String.t()) :: {:ok, %{auth_url: String.t(), service: String.t()}} | {:error, term()}
  def start_flow(service) do
    state = generate_state()

    with :ok <- store_state(state, service),
         {:ok, url} <- Config.auth_url(service, state) do
      {:ok, %{auth_url: url, service: service, state: state}}
    end
  end

  @doc """
  Handles the OAuth2 callback from the provider.

  Verifies the CSRF state, exchanges the authorization code for an access token,
  and persists the token. Returns `{:ok, service}` on success.
  """
  @spec handle_callback(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def handle_callback(service, code, state) do
    with {:ok, expected_service} <- StateStore.pop(state),
         :ok <- verify_service(expected_service, service),
         {:ok, config} <- Config.get(service),
         {:ok, token_data} <- exchange_code(service, config, code),
         :ok <- save_token(service, token_data) do
      {:ok, service}
    end
  end

  @doc """
  Returns the stored OAuth token data for a service.

  Returns `{:error, :not_found}` when no token is stored.
  """
  @spec get_token(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_token(service) do
    tokens = load_tokens()

    case Map.fetch(tokens, service) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, :not_found}
    end
  end

  @doc "Removes the stored OAuth token for a service."
  @spec revoke_token(String.t()) :: :ok
  def revoke_token(service) do
    tokens = load_tokens()
    save_tokens(Map.delete(tokens, service))
  end

  @doc "Returns a map of service name → token summary (no secrets exposed)."
  @spec list_tokens() :: %{String.t() => %{connected: true, scope: String.t() | nil}}
  def list_tokens do
    load_tokens()
    |> Map.new(fn {service, token} ->
      {service, %{connected: true, scope: token["scope"]}}
    end)
  end

  @doc "Returns whether a service has a stored OAuth token."
  @spec connected?(String.t()) :: boolean()
  def connected?(service) do
    match?({:ok, _}, get_token(service))
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp generate_state do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  defp store_state(state, service) do
    case Process.whereis(StateStore) do
      nil -> {:error, "OAuth flow requires the Codrift server to be running (start the TUI first)"}
      _pid -> StateStore.put(state, service)
    end
  end

  defp verify_service(expected, actual) when expected == actual, do: :ok
  defp verify_service(expected, actual),
    do: {:error, "OAuth state service mismatch: expected #{expected}, got #{actual}"}

  defp exchange_code(service, config, code) do
    client_id = System.get_env(config.client_id_env)
    client_secret = System.get_env(config.client_secret_env)

    cond do
      is_nil(client_id) ->
        {:error, "#{config.client_id_env} env var not set"}

      is_nil(client_secret) ->
        {:error, "#{config.client_secret_env} env var not set"}

      true ->
        do_exchange(config.token_format, config.token_url, %{
          client_id: client_id,
          client_secret: client_secret,
          code: code,
          redirect_uri: Config.redirect_uri(service),
          grant_type: "authorization_code"
        })
    end
  end

  defp do_exchange(:form, token_url, params) do
    headers = [{"accept", "application/json"}]
    HTTP.post(token_url, params, headers)
  end

  defp do_exchange(:json, token_url, params) do
    HTTP.post(token_url, params, [])
  end

  defp do_exchange(:notion, token_url, %{client_id: id, client_secret: secret} = params) do
    encoded = Base.encode64("#{id}:#{secret}")
    headers = [{"authorization", "Basic #{encoded}"}]
    HTTP.post(token_url, Map.drop(params, [:client_id, :client_secret]), headers)
  end

  defp save_token(service, token_data) do
    tokens = load_tokens()
    save_tokens(Map.put(tokens, service, token_data))
  end

  defp load_tokens do
    path = Path.expand(@token_file)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, data} <- JSON.decode(content),
         true <- is_map(data) do
      data
    else
      _ -> %{}
    end
  end

  defp save_tokens(tokens) do
    path = Path.expand(@token_file)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, JSON.encode!(tokens))
    File.chmod!(path, 0o600)
    :ok
  end
end

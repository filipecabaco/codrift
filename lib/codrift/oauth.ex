defmodule Codrift.OAuth do
  @moduledoc """
  Auth management for Codrift external integrations.

  ## Flow types

  ### PKCE browser flow (Linear, GitLab, Jira)

  RFC 7636 — no client secret stored or shipped:
  1. `start_flow/1` → returns `{:ok, %{flow: :pkce_browser, auth_url: url}}`.
  2. Provider redirects to `localhost:7437/oauth/callback/{service}`.
  3. `handle_callback/3` exchanges code + verifier, enriches token (Jira: fetches cloudId), saves.

  ### Device Flow (GitHub)

  RFC 8628 — no redirect URI, no secret, designed for CLI tools:
  1. `start_flow/1` → requests a device code, returns `{:ok, %{flow: :device_flow, user_code: _, verification_uri: _}}`.
  2. User visits `verification_uri` and enters `user_code`.
  3. `poll_device_auth/5` starts a supervised Task that polls until token arrives, then saves it and notifies the caller via message.

  ### Guided token (Notion)

  No OAuth — user pastes a token from the service web UI:
  1. `start_flow/1` → returns `{:ok, %{flow: :guided_token, instructions: _}}`.
  2. `save_guided_token/2` validates prefix and saves.

  ## Token storage

  `~/.codrift/oauth_tokens.json` (mode 0600), keyed by service name.
  Adapters call `get_token/1` first and fall back to env vars.
  """

  alias Codrift.Integration.HTTP
  alias Codrift.OAuth.Config
  alias Codrift.OAuth.StateStore

  @token_file "~/.codrift/oauth_tokens.json"

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Starts an auth flow for a service.

  - PKCE: `{:ok, %{flow: :pkce_browser, auth_url: url, service: service}}`
  - Device Flow: `{:ok, %{flow: :device_flow, service: service, user_code: _, verification_uri: _, device_code: _, expires_in: _, interval: _}}`
  - Guided token: `{:ok, %{flow: :guided_token, service: service, instructions: text}}`
  """
  @spec start_flow(String.t()) :: {:ok, map()} | {:error, term()}
  def start_flow(service) do
    with {:ok, config} <- Config.get(service) do
      case config.flow do
        :pkce_browser ->
          start_pkce_flow(service, config)

        :device_flow ->
          start_device_flow(service, config)

        :guided_token ->
          {:ok, %{flow: :guided_token, service: service, instructions: config.instructions}}
      end
    end
  end

  @doc """
  Handles the PKCE callback from the provider.

  Exchanges `code + verifier`, runs any service-specific post-processing
  (e.g. Jira fetches cloudId), and saves the enriched token.
  """
  @spec handle_callback(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def handle_callback(service, code, state) do
    with {:ok, expected_service, verifier} <- StateStore.pop(state),
         :ok <- verify_service(expected_service, service),
         {:ok, config} <- Config.get(service),
         {:ok, client_id} <- Config.resolve_client_id(config, service),
         {:ok, token_data} <- exchange_code(config, code, client_id, verifier, service),
         {:ok, enriched} <- enrich_token(service, token_data),
         :ok <- save_token(service, enriched) do
      {:ok, service}
    end
  end

  @doc """
  Starts a supervised background Task that polls GitHub until the device code
  is authorized or expires, then saves the token and sends one of:

    `{:device_auth_complete, service, return_to}`
    `{:device_auth_failed, service, reason, return_to}`

  to `notify_pid`. `return_to` is passed through unchanged for the caller to
  use for post-auth navigation.
  """
  @spec poll_device_auth(pid(), String.t(), String.t(), integer(), integer(), term()) :: :ok
  def poll_device_auth(notify_pid, service, device_code, expires_at, interval, return_to) do
    with {:ok, config} <- Config.get(service),
         {:ok, client_id} <- Config.resolve_client_id(config, service) do
      params = %{
        client_id: client_id,
        device_code: device_code,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code"
      }

      Task.Supervisor.start_child(Codrift.TaskSupervisor, fn ->
        do_poll(notify_pid, service, config.token_url, params, expires_at, interval, return_to)
      end)
    end

    :ok
  end

  @doc """
  Validates and saves a guided token (e.g. Notion internal integration secret).

  Returns `{:error, reason}` when the token format is wrong for the service.
  """
  @spec save_guided_token(String.t(), String.t()) :: :ok | {:error, String.t()}
  def save_guided_token(service, token) do
    with {:ok, config} <- Config.get(service),
         :guided_token <- config.flow,
         :ok <- validate_guided_token(token, config) do
      save_token(service, %{"access_token" => token, "token_type" => "guided"})
    else
      :pkce_browser ->
        {:error, "#{service} uses browser OAuth, not guided token setup"}

      {:error, _} = err ->
        err
    end
  end

  @doc "Returns the stored token data for a service, or `{:error, :not_found}`."
  @spec get_token(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_token(service) do
    case Map.fetch(load_tokens(), service) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, :not_found}
    end
  end

  @doc "Removes the stored token for a service."
  @spec revoke_token(String.t()) :: :ok
  def revoke_token(service) do
    load_tokens() |> Map.delete(service) |> save_tokens()
  end

  @doc "Returns a map of service → connection summary (no raw tokens exposed)."
  @spec list_tokens() :: map()
  def list_tokens do
    Map.new(load_tokens(), fn {service, token} ->
      {service, %{connected: true, type: token["token_type"], scope: token["scope"]}}
    end)
  end

  @doc "Returns whether a service has any stored token."
  @spec connected?(String.t()) :: boolean()
  def connected?(service), do: match?({:ok, _}, get_token(service))

  # ── PKCE helpers ─────────────────────────────────────────────────────────────

  defp start_pkce_flow(service, _config) do
    verifier = generate_verifier()
    challenge = derive_challenge(verifier)
    state = generate_state()

    with :ok <- store_state(state, service, verifier),
         {:ok, url} <- Config.auth_url(service, state, challenge) do
      {:ok, %{flow: :pkce_browser, auth_url: url, service: service}}
    end
  end

  # RFC 7636 §4.1 — 43-128 unreserved characters; 64 random bytes gives 86 chars
  defp generate_verifier do
    :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)
  end

  # RFC 7636 §4.2 — BASE64URL(SHA256(ASCII(code_verifier)))
  defp derive_challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp generate_state do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  defp store_state(state, service, verifier) do
    case Process.whereis(StateStore) do
      nil ->
        {:error, "OAuth flow requires the Codrift server to be running. Start the TUI first."}

      _pid ->
        StateStore.put(state, service, verifier)
    end
  end

  defp verify_service(expected, actual) when expected == actual, do: :ok

  defp verify_service(expected, actual),
    do: {:error, "state/service mismatch: expected #{expected}, got #{actual}"}

  # ── Device Flow ───────────────────────────────────────────────────────────────

  defp start_device_flow(service, config) do
    with {:ok, client_id} <- Config.resolve_client_id(config, service),
         {:ok, data} <- request_device_code(config.device_code_url, client_id, config[:scopes]) do
      {:ok,
       %{
         flow: :device_flow,
         service: service,
         user_code: data["user_code"],
         verification_uri: data["verification_uri"] || "https://github.com/login/device",
         device_code: data["device_code"],
         expires_in: data["expires_in"] || 900,
         interval: data["interval"] || 5
       }}
    end
  end

  defp request_device_code(url, client_id, scopes) do
    params = %{client_id: client_id, scope: scopes}
    HTTP.post(url, params, [{"accept", "application/json"}])
  end

  # Tail-recursive poller — runs inside a Task.Supervisor child.
  defp do_poll(notify_pid, service, token_url, params, expires_at, interval, return_to) do
    :timer.sleep(interval * 1_000)

    if System.os_time(:second) >= expires_at do
      send(notify_pid, {:device_auth_failed, service, "device code expired", return_to})
    else
      case HTTP.post(token_url, params, [{"accept", "application/json"}]) do
        {:ok, %{"access_token" => _} = token_data} ->
          save_token(service, token_data)
          send(notify_pid, {:device_auth_complete, service, return_to})

        {:ok, %{"error" => "authorization_pending"}} ->
          do_poll(notify_pid, service, token_url, params, expires_at, interval, return_to)

        {:ok, %{"error" => "slow_down"}} ->
          do_poll(notify_pid, service, token_url, params, expires_at, interval + 5, return_to)

        {:ok, %{"error" => reason}} ->
          send(notify_pid, {:device_auth_failed, service, reason, return_to})

        {:error, _} ->
          do_poll(notify_pid, service, token_url, params, expires_at, interval, return_to)
      end
    end
  end

  # ── Token enrichment (service-specific post-processing) ───────────────────────

  # Jira: after PKCE exchange fetch cloudId + site URL from accessible-resources.
  defp enrich_token("jira", token_data) do
    with {:ok, resources} <- fetch_atlassian_resources(token_data["access_token"]),
         {:ok, cloud_id, site_url} <- extract_atlassian_cloud(resources) do
      {:ok, Map.merge(token_data, %{"cloud_id" => cloud_id, "cloud_site_url" => site_url})}
    end
  end

  defp enrich_token(_service, token_data), do: {:ok, token_data}

  defp fetch_atlassian_resources(access_token) do
    HTTP.get(
      "https://api.atlassian.com/oauth/token/accessible-resources",
      [{"authorization", "Bearer #{access_token}"}, {"accept", "application/json"}]
    )
  end

  defp extract_atlassian_cloud([%{"id" => id, "url" => url} | _]), do: {:ok, id, url}
  defp extract_atlassian_cloud([]), do: {:error, "no accessible Jira resources found"}

  defp extract_atlassian_cloud(_),
    do: {:error, "unexpected response from Atlassian resources API"}

  # ── Token exchange ────────────────────────────────────────────────────────────

  defp exchange_code(config, code, client_id, verifier, service) do
    params = %{
      client_id: client_id,
      code: code,
      redirect_uri: Config.redirect_uri(service),
      grant_type: "authorization_code",
      code_verifier: verifier
    }

    HTTP.post(config.token_url, params, [{"accept", "application/json"}])
  end

  # ── Guided token validation ───────────────────────────────────────────────────

  defp validate_guided_token(token, %{token_prefixes: prefixes}) do
    if Enum.any?(prefixes, &String.starts_with?(token, &1)) do
      :ok
    else
      {:error,
       "invalid token format — expected a token starting with #{Enum.join(prefixes, " or ")}"}
    end
  end

  defp validate_guided_token(_token, _config), do: :ok

  # ── Storage ──────────────────────────────────────────────────────────────────

  defp save_token(service, token_data) do
    load_tokens() |> Map.put(service, token_data) |> save_tokens()
  end

  defp load_tokens do
    path = Path.expand(@token_file)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, data} when is_map(data) <- JSON.decode(content) do
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

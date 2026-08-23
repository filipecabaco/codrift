defmodule Codrift.OAuth do
  @moduledoc """
  Auth management for Codrift external integrations.

  ## Flow types

  ### PKCE browser flow (Linear, GitLab)

  RFC 7636 — no client secret stored or shipped:
  1. `start_flow/1` → returns `{:ok, %{flow: :pkce_browser, auth_url: url}}`.
  2. Provider redirects to `127.0.0.1:43117/oauth/callback/{service}`.
  3. `handle_callback/3` exchanges code + verifier, saves the token.

  ### Device Flow (GitHub)

  RFC 8628 — no redirect URI, no secret, designed for CLI tools:
  1. `start_flow/1` → requests a device code, returns `{:ok, %{flow: :device_flow, user_code: _, verification_uri: _}}`.
  2. User visits `verification_uri` and enters `user_code`.
  3. `poll_device_auth/5` starts a supervised Task that polls until token arrives, then saves it and notifies the caller via message.

  ## Token storage and lifetime

  `~/.codrift/oauth_tokens.json` (mode 0600), keyed by service name.

  Adapters call `access_token/1`, not `get_token/1`: **Linear access tokens live
  24 hours** (`expires_in: 86399`) and GitLab's live two, and neither provider
  offers any way to ask for longer — Linear's `/authorize` has no lifetime
  parameter at all. Before refresh existed, connecting Linear worked beautifully
  and then 401'd every request the next day, which is what
  `%{"errors" => [%{"extensions" => %{"code" => "AUTHENTICATION_ERROR"` in the
  initiative picker actually was.

  So every saved token is stamped with `expires_at`, and `access_token/1`
  exchanges the stored `refresh_token` for a new pair a couple of minutes before
  that deadline. Only when there is no refresh token, or the provider rejects
  it, does the user have to reconnect — and then the caller gets
  `{:error, :reauth_required}` to say so plainly.

  GitHub's device-flow tokens do not expire and carry no `expires_in`; they are
  stamped with nothing and never refreshed.
  """

  alias Codrift.Integration.HTTP
  alias Codrift.OAuth.Config
  alias Codrift.OAuth.StateStore

  defp token_file, do: Path.join(Codrift.Paths.data_dir(), "oauth_tokens.json")

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Starts an auth flow for a service.

  - PKCE: `{:ok, %{flow: :pkce_browser, auth_url: url, service: service}}`
  - Device Flow: `{:ok, %{flow: :device_flow, service: service, user_code: _, verification_uri: _, device_code: _, expires_in: _, interval: _}}`
  """
  @spec start_flow(String.t()) :: {:ok, map()} | {:error, term()}
  def start_flow(service) do
    with {:ok, config} <- Config.get(service) do
      case config.flow do
        :pkce_browser ->
          start_pkce_flow(service, config)

        :device_flow ->
          start_device_flow(service, config)
      end
    end
  end

  @doc """
  Handles the PKCE callback from the provider.

  Exchanges `code + verifier` and saves the resulting token.
  """
  @spec handle_callback(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def handle_callback(service, code, state) do
    with {:ok, expected_service, verifier} <- StateStore.pop(state),
         :ok <- verify_service(expected_service, service),
         {:ok, config} <- Config.get(service),
         {:ok, client_id} <- Config.resolve_client_id(config, service),
         {:ok, token_data} <- exchange_code(config, code, client_id, verifier, service),
         :ok <- save_token(service, token_data) do
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

  `notify_pid` may be `nil` when the caller has no live process to notify
  (e.g. a stateless web RPC that polls `connected?/1` instead) — the token is
  still saved either way.
  """
  @spec poll_device_auth(pid() | nil, String.t(), String.t(), integer(), integer(), term()) :: :ok
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

  @doc "Returns the stored token data for a service, or `{:error, :not_found}`."
  @spec get_token(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_token(service) do
    case Map.fetch(load_tokens(), service) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Returns a token that is good to send *right now*, refreshing it if need be.

  This is what adapters should call. `get_token/1` hands back whatever is on
  disk, which for Linear is very often a token that expired overnight.

  - `{:ok, access_token}` — usable, possibly just refreshed and re-saved.
  - `{:error, :not_found}` — never connected; the caller may fall back to an
    env-var API key.
  - `{:error, :reauth_required}` — connected once, but the grant is spent. Only
    a new browser flow fixes it.
  """
  @spec access_token(String.t()) :: {:ok, String.t()} | {:error, :not_found | :reauth_required}
  def access_token(service) do
    with {:ok, token} <- get_token(service) do
      if fresh?(token), do: {:ok, token["access_token"]}, else: refresh(service, token)
    end
  end

  @doc """
  Trades the stored refresh token for a fresh pair and saves it.

  Exposed for the UI's "reconnect" affordance to try the cheap fix before
  sending the user through a browser flow.
  """
  @spec refresh(String.t()) :: {:ok, String.t()} | {:error, :not_found | :reauth_required}
  def refresh(service) do
    with {:ok, token} <- get_token(service), do: refresh(service, token)
  end

  @doc """
  Connection state for a service, as the settings UI wants to show it.

  `needs_reauth` is the interesting field: a token can be present and still be
  useless, and the UI has to offer Reconnect rather than Disconnect in that case.
  """
  @spec status(String.t()) :: map()
  def status(service) do
    case get_token(service) do
      {:ok, token} ->
        %{
          connected: true,
          type: token["token_type"],
          scope: token["scope"],
          expires_at: token["expires_at"],
          # Expiry alone is not a problem — a refreshable token renews itself on
          # the next call. Only an expired token with nothing to renew it is.
          needs_reauth: not fresh?(token) and not refreshable?(token)
        }

      {:error, :not_found} ->
        %{connected: false, needs_reauth: false}
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
    Map.new(load_tokens(), fn {service, _token} -> {service, status(service)} end)
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
    HTTP.post_form(url, params, [{"accept", "application/json"}])
  end

  # Tail-recursive poller — runs inside a Task.Supervisor child.
  defp do_poll(notify_pid, service, token_url, params, expires_at, interval, return_to) do
    :timer.sleep(interval * 1_000)

    if System.os_time(:second) >= expires_at do
      notify(notify_pid, {:device_auth_failed, service, "device code expired", return_to})
    else
      case HTTP.post_form(token_url, params, [{"accept", "application/json"}]) do
        {:ok, %{"access_token" => _} = token_data} ->
          save_token(service, token_data)
          notify(notify_pid, {:device_auth_complete, service, return_to})

        {:ok, %{"error" => "authorization_pending"}} ->
          do_poll(notify_pid, service, token_url, params, expires_at, interval, return_to)

        {:ok, %{"error" => "slow_down"}} ->
          do_poll(notify_pid, service, token_url, params, expires_at, interval + 5, return_to)

        {:ok, %{"error" => reason}} ->
          notify(notify_pid, {:device_auth_failed, service, reason, return_to})

        {:error, _} ->
          do_poll(notify_pid, service, token_url, params, expires_at, interval, return_to)
      end
    end
  end

  defp notify(nil, _msg), do: :ok
  defp notify(pid, msg) when is_pid(pid), do: send(pid, msg)

  # ── Token exchange ────────────────────────────────────────────────────────────

  defp exchange_code(config, code, client_id, verifier, service) do
    params = %{
      client_id: client_id,
      code: code,
      redirect_uri: Config.redirect_uri(service),
      grant_type: "authorization_code",
      code_verifier: verifier
    }

    HTTP.post_form(config.token_url, params, [{"accept", "application/json"}])
  end

  # ── Refresh ──────────────────────────────────────────────────────────────────

  # Refresh a little before the provider's own deadline. The token has to outlive
  # the request we are about to make, and the clock here and the clock there
  # agree only approximately.
  @refresh_skew_seconds 120

  defp refresh(service, token) do
    with true <- refreshable?(token),
         {:ok, config} <- Config.get(service),
         {:ok, client_id} <- Config.resolve_client_id(config, service),
         {:ok, %{"access_token" => _} = renewed} <-
           request_refresh(config.token_url, token["refresh_token"], client_id) do
      # Providers that rotate refresh tokens return a new one; providers that do
      # not simply omit the field. Merging *over* the old blob keeps the existing
      # refresh token in the second case — replacing it outright would log the
      # user out on the following refresh.
      saved = token |> Map.merge(renewed) |> stamp_expiry()
      save_token(service, saved)
      {:ok, saved["access_token"]}
    else
      _ -> {:error, :reauth_required}
    end
  end

  defp request_refresh(token_url, refresh_token, client_id) do
    HTTP.post_form(
      token_url,
      %{
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: client_id
      },
      [{"accept", "application/json"}]
    )
  end

  defp refreshable?(%{"refresh_token" => token}) when is_binary(token) and token != "", do: true
  defp refreshable?(_), do: false

  # No recorded deadline means no deadline to miss: GitHub's device-flow tokens
  # genuinely never expire, and tokens saved before `expires_at` existed have
  # nothing to compare against — treating those as stale would sign everyone out
  # on upgrade for no reason.
  defp fresh?(%{"expires_at" => at}) when is_integer(at),
    do: System.os_time(:second) + @refresh_skew_seconds < at

  defp fresh?(_), do: true

  # ── Storage ──────────────────────────────────────────────────────────────────

  defp save_token(service, token_data) do
    load_tokens() |> Map.put(service, stamp_expiry(token_data)) |> save_tokens()
  end

  # `expires_in` is relative to the moment the provider answered, which is no use
  # to a token store that outlives the process. Resolve it to an absolute second
  # once, here, so every later freshness check is a plain comparison.
  defp stamp_expiry(%{"expires_in" => seconds} = token) when is_integer(seconds) and seconds > 0,
    do: Map.put(token, "expires_at", System.os_time(:second) + seconds)

  defp stamp_expiry(%{"expires_in" => seconds} = token) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {parsed, _} when parsed > 0 -> stamp_expiry(Map.put(token, "expires_in", parsed))
      _ -> token
    end
  end

  defp stamp_expiry(token), do: token

  defp load_tokens do
    path = token_file()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, data} when is_map(data) <- JSON.decode(content) do
      data
    else
      _ -> %{}
    end
  end

  # Same shape as `Codrift.AuthToken`: the temp file is chmod'ed 0600 while still
  # empty, so access tokens are never on disk under the umask default, and the
  # rename is atomic — a crash mid-write cannot leave a truncated token store
  # behind (which `load_tokens/0` would silently read as "no tokens").
  defp save_tokens(tokens) do
    path = token_file()
    path |> Path.dirname() |> File.mkdir_p!()
    tmp = path <> ".tmp"
    fd = File.open!(tmp, [:write])
    File.chmod!(tmp, 0o600)
    IO.binwrite(fd, JSON.encode!(tokens))
    File.close(fd)
    File.rename!(tmp, path)
    :ok
  end
end

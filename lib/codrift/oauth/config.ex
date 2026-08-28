defmodule Codrift.OAuth.Config do
  @moduledoc """
  OAuth2 / auth configuration for each supported external service.

  ## Flow types

  - `:pkce_browser` — RFC 7636 PKCE + localhost redirect. No client secret
    needed or stored. `client_id` only (safe to ship in the binary).
    Services: linear, linear_projects, gitlab.

  - `:device_flow` — GitHub Device Flow (RFC 8628). No redirect URI, no secret.
    User visits github.com/login/device and enters a short code.
    Services: github, github_projects.

  ## Registering apps

  PKCE services — redirect URI:
  `http://127.0.0.1:43117/oauth/callback/<oauth app>`

  The last segment names the registered *app*, not the service. Two services can
  be two views of one provider account behind one app — `linear` and
  `linear_projects` are — and a provider only ever redirects to a URI that app
  registered. Such a service carries `:oauth_app`, and shares the callback of
  the service it names; everything else calls back on its own name.

  The literal loopback IP, not `localhost`: Bandit binds IPv4 `127.0.0.1` only
  (see `config/config.exs`), while `localhost` may resolve to `::1` first. RFC
  8252 §7.3 recommends the literal IP for native-app loopback redirects for
  exactly this reason. The port is fixed because providers store the redirect
  URI at registration time and it cannot be renegotiated at runtime.
  Device Flow  — no redirect URI needed; register a GitHub OAuth App.

  `client_id` resolution order:
    1. `{SERVICE}_CLIENT_ID` env var
    2. Codrift's hardcoded client ID (set once registered apps exist)
  """

  @port 43_117

  @services %{
    "github" => %{
      flow: :device_flow,
      device_code_url: "https://github.com/login/device/code",
      token_url: "https://github.com/login/oauth/access_token",
      client_id_env: "GITHUB_CLIENT_ID",
      client_id: "Ov23lifrU89AdlZ0GOih",
      scopes: "repo read:org project"
    },
    "github_projects" => %{
      flow: :device_flow,
      device_code_url: "https://github.com/login/device/code",
      token_url: "https://github.com/login/oauth/access_token",
      client_id_env: "GITHUB_CLIENT_ID",
      client_id: "Ov23lifrU89AdlZ0GOih",
      scopes: "repo read:org project"
    },
    "linear" => %{
      flow: :pkce_browser,
      auth_url: "https://linear.app/oauth/authorize",
      token_url: "https://api.linear.app/oauth/token",
      client_id_env: "LINEAR_CLIENT_ID",
      client_id: "17a8b9b39ebdd14c9c2e600f1ac51141",
      scopes: "read"
    },
    "linear_projects" => %{
      flow: :pkce_browser,
      auth_url: "https://linear.app/oauth/authorize",
      token_url: "https://api.linear.app/oauth/token",
      client_id_env: "LINEAR_CLIENT_ID",
      client_id: "17a8b9b39ebdd14c9c2e600f1ac51141",
      # The same registered Linear app as "linear" — same client ID, so the same
      # redirect URI is the only one it will accept. Asking it to redirect to
      # /oauth/callback/linear_projects is what Linear turns down as "Invalid
      # redirect_uri parameter for the application".
      oauth_app: "linear",
      scopes: "read"
    },
    "gitlab" => %{
      flow: :pkce_browser,
      auth_url: "https://gitlab.com/oauth/authorize",
      token_url: "https://gitlab.com/oauth/token",
      client_id_env: "GITLAB_CLIENT_ID",
      client_id: "734af289d7dc4abd701f471c1c17dc6470cc58ba8b23bf3077736bb95dd05372",
      scopes: "read_api read_user"
    }
  }

  @doc "Returns the config map for a named service."
  @spec get(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get(service) do
    case Map.fetch(@services, service) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, "no OAuth/auth config for service: #{service}"}
    end
  end

  @doc "Returns all services with browser-based PKCE OAuth support."
  @spec pkce_services() :: [String.t()]
  def pkce_services do
    @services
    |> Enum.filter(fn {_, c} -> c.flow == :pkce_browser end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "Returns all services using GitHub Device Flow."
  @spec device_flow_services() :: [String.t()]
  def device_flow_services do
    @services
    |> Enum.filter(fn {_, c} -> c.flow == :device_flow end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "Returns all services that support any form of auth flow (PKCE or device flow)."
  @spec supported_services() :: [String.t()]
  def supported_services, do: @services |> Map.keys() |> Enum.sort()

  @doc """
  Returns the redirect URI a PKCE service's provider will call back on.

  Keyed by the registered OAuth app rather than the service, because that is
  what the provider matches against. See `callback_name/1`.
  """
  @spec redirect_uri(String.t()) :: String.t()
  def redirect_uri(service),
    do: "http://127.0.0.1:#{@port}/oauth/callback/#{callback_name(service)}"

  @doc """
  The path segment a service's callback arrives on.

  A service's own name, unless it shares a registered app with another service —
  then the app's name, since the redirect URI belongs to the app.
  """
  @spec callback_name(String.t()) :: String.t()
  def callback_name(service) do
    case get(service) do
      {:ok, %{oauth_app: app}} -> app
      _ -> service
    end
  end

  @doc """
  Builds the PKCE authorization URL for a service.

  Requires `flow: :pkce_browser`. Returns `{:error, reason}` when the service
  uses a different flow or the client ID cannot be resolved.
  """
  @spec auth_url(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def auth_url(service, state, code_challenge) do
    with {:ok, %{flow: :pkce_browser} = config} <- get(service),
         {:ok, client_id} <- resolve_client_id(config, service) do
      params =
        %{
          client_id: client_id,
          redirect_uri: redirect_uri(service),
          response_type: "code",
          state: state,
          code_challenge: code_challenge,
          code_challenge_method: "S256"
        }
        |> maybe_add_scopes(config)
        |> maybe_add_extras(service)
        |> URI.encode_query()

      {:ok, "#{config.auth_url}?#{params}"}
    else
      # A device-flow service has no redirect URI to send anyone to. Without
      # this clause the `with` fell through with nothing matching and raised
      # WithClauseError, contradicting the contract above — and crashing the
      # request instead of reporting a service that simply asks to be started a
      # different way.
      {:ok, %{flow: flow}} ->
        {:error, "#{service} authenticates by #{flow}, not a browser redirect"}

      {:error, _} = err ->
        err
    end
  end

  @doc "Resolves the client ID for a service (env var overrides hardcoded default)."
  @spec resolve_client_id(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_client_id(config, service) do
    case System.get_env(config.client_id_env) || config.client_id do
      nil ->
        {:error,
         "#{config.client_id_env} env var is required to use OAuth for #{service}. " <>
           "Register an OAuth app at the service's developer portal and set the redirect URI to: " <>
           redirect_uri(service)}

      id ->
        {:ok, id}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp maybe_add_scopes(params, %{scopes: s}), do: Map.put(params, :scope, s)

  defp maybe_add_extras(params, _), do: params
end

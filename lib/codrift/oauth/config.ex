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

  PKCE services — redirect URI: `http://localhost:7437/oauth/callback/<service>`
  Device Flow  — no redirect URI needed; register a GitHub OAuth App.

  `client_id` resolution order:
    1. `{SERVICE}_CLIENT_ID` env var
    2. Codrift's hardcoded client ID (set once registered apps exist)
  """

  @port 7437

  @services %{
    "github" => %{
      flow: :device_flow,
      device_code_url: "https://github.com/login/device/code",
      token_url: "https://github.com/login/oauth/access_token",
      client_id_env: "GITHUB_CLIENT_ID",
      client_id: nil,
      scopes: "repo read:org project"
    },
    "github_projects" => %{
      flow: :device_flow,
      device_code_url: "https://github.com/login/device/code",
      token_url: "https://github.com/login/oauth/access_token",
      client_id_env: "GITHUB_CLIENT_ID",
      client_id: nil,
      scopes: "repo read:org project"
    },
    "linear" => %{
      flow: :pkce_browser,
      auth_url: "https://linear.app/oauth/authorize",
      token_url: "https://api.linear.app/oauth/token",
      client_id_env: "LINEAR_CLIENT_ID",
      client_id: nil,
      scopes: "read",
      token_format: :json
    },
    "linear_projects" => %{
      flow: :pkce_browser,
      auth_url: "https://linear.app/oauth/authorize",
      token_url: "https://api.linear.app/oauth/token",
      client_id_env: "LINEAR_CLIENT_ID",
      client_id: nil,
      scopes: "read",
      token_format: :json
    },
    "gitlab" => %{
      flow: :pkce_browser,
      auth_url: "https://gitlab.com/oauth/authorize",
      token_url: "https://gitlab.com/oauth/token",
      client_id_env: "GITLAB_CLIENT_ID",
      client_id: nil,
      scopes: "read_api read_user",
      token_format: :json
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

  @doc "Returns the redirect URI for a PKCE service."
  @spec redirect_uri(String.t()) :: String.t()
  def redirect_uri(service), do: "http://localhost:#{@port}/oauth/callback/#{service}"

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

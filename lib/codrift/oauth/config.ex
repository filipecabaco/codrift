defmodule Codrift.OAuth.Config do
  @moduledoc """
  OAuth2 configuration for each supported external service.

  Each entry defines the authorization URL, token exchange URL, required scopes,
  and which environment variables hold the client credentials the user registered
  in their OAuth app settings.

  ## Registering an OAuth app

  Each service requires you to register an application and set the redirect URI to:

      http://localhost:7437/oauth/callback/<service>

  Environment variables needed per service:

  | Service  | Client ID env        | Client Secret env        |
  |----------|---------------------|--------------------------|
  | github   | GITHUB_CLIENT_ID    | GITHUB_CLIENT_SECRET     |
  | linear   | LINEAR_CLIENT_ID    | LINEAR_CLIENT_SECRET     |
  | gitlab   | GITLAB_CLIENT_ID    | GITLAB_CLIENT_SECRET     |
  | notion   | NOTION_CLIENT_ID    | NOTION_CLIENT_SECRET     |
  | jira     | JIRA_CLIENT_ID      | JIRA_CLIENT_SECRET       |
  | asana    | ASANA_CLIENT_ID     | ASANA_CLIENT_SECRET      |
  """

  @port 7437

  @services %{
    "github" => %{
      auth_url: "https://github.com/login/oauth/authorize",
      token_url: "https://github.com/login/oauth/access_token",
      client_id_env: "GITHUB_CLIENT_ID",
      client_secret_env: "GITHUB_CLIENT_SECRET",
      scopes: "repo read:org project",
      token_format: :form
    },
    "github_projects" => %{
      auth_url: "https://github.com/login/oauth/authorize",
      token_url: "https://github.com/login/oauth/access_token",
      client_id_env: "GITHUB_CLIENT_ID",
      client_secret_env: "GITHUB_CLIENT_SECRET",
      scopes: "repo read:org project",
      token_format: :form
    },
    "linear" => %{
      auth_url: "https://linear.app/oauth/authorize",
      token_url: "https://api.linear.app/oauth/token",
      client_id_env: "LINEAR_CLIENT_ID",
      client_secret_env: "LINEAR_CLIENT_SECRET",
      scopes: "read",
      token_format: :json
    },
    "linear_projects" => %{
      auth_url: "https://linear.app/oauth/authorize",
      token_url: "https://api.linear.app/oauth/token",
      client_id_env: "LINEAR_CLIENT_ID",
      client_secret_env: "LINEAR_CLIENT_SECRET",
      scopes: "read",
      token_format: :json
    },
    "gitlab" => %{
      auth_url: "https://gitlab.com/oauth/authorize",
      token_url: "https://gitlab.com/oauth/token",
      client_id_env: "GITLAB_CLIENT_ID",
      client_secret_env: "GITLAB_CLIENT_SECRET",
      scopes: "read_api read_user",
      token_format: :json
    },
    "notion" => %{
      auth_url: "https://api.notion.com/v1/oauth/authorize",
      token_url: "https://api.notion.com/v1/oauth/token",
      client_id_env: "NOTION_CLIENT_ID",
      client_secret_env: "NOTION_CLIENT_SECRET",
      scopes: nil,
      token_format: :notion
    },
    "jira" => %{
      auth_url: "https://auth.atlassian.com/authorize",
      token_url: "https://auth.atlassian.com/oauth/token",
      client_id_env: "JIRA_CLIENT_ID",
      client_secret_env: "JIRA_CLIENT_SECRET",
      scopes: "read:jira-work read:jira-user offline_access",
      token_format: :json
    },
    "asana" => %{
      auth_url: "https://app.asana.com/-/oauth_authorize",
      token_url: "https://app.asana.com/-/oauth_token",
      client_id_env: "ASANA_CLIENT_ID",
      client_secret_env: "ASANA_CLIENT_SECRET",
      scopes: "default",
      token_format: :json
    }
  }

  @doc "Returns the config map for a named service, or `{:error, reason}`."
  @spec get(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get(service) do
    case Map.fetch(@services, service) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, "OAuth2 not supported for service: #{service}"}
    end
  end

  @doc "Returns the list of services that support OAuth2."
  @spec supported_services() :: [String.t()]
  def supported_services, do: Map.keys(@services)

  @doc "Builds the redirect URI for a service."
  @spec redirect_uri(String.t()) :: String.t()
  def redirect_uri(service), do: "http://localhost:#{@port}/oauth/callback/#{service}"

  @doc """
  Builds the full authorization URL for a service.

  Returns `{:error, reason}` when the client ID env var is not set.
  """
  @spec auth_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def auth_url(service, state) do
    with {:ok, config} <- get(service) do
      client_id = System.get_env(config.client_id_env)

      unless client_id do
        {:error, "#{config.client_id_env} env var is required to use OAuth for #{service}"}
      else
        params =
          %{
            client_id: client_id,
            redirect_uri: redirect_uri(service),
            response_type: "code",
            state: state
          }
          |> maybe_add_scopes(config)
          |> maybe_add_audience(service)
          |> URI.encode_query()

        {:ok, "#{config.auth_url}?#{params}"}
      end
    end
  end

  defp maybe_add_scopes(params, %{scopes: nil}), do: params
  defp maybe_add_scopes(params, %{scopes: s}), do: Map.put(params, :scope, s)

  # Jira requires audience=api.atlassian.com and prompt=consent
  defp maybe_add_audience(params, "jira") do
    Map.merge(params, %{audience: "api.atlassian.com", prompt: "consent"})
  end

  # Notion requires owner=user
  defp maybe_add_audience(params, "notion") do
    Map.put(params, :owner, "user")
  end

  defp maybe_add_audience(params, _), do: params
end

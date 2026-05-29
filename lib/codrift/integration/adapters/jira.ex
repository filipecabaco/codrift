defmodule Codrift.Integration.Adapters.Jira do
  @moduledoc """
  Jira Cloud integration adapter (REST API v3).

  ## Auth

  ### OAuth (preferred)
  Run `codrift integration auth jira` (TUI must be running). After PKCE, Codrift
  fetches `cloud_id` + `cloud_site_url` from Atlassian automatically.
  API calls go to `api.atlassian.com/ex/jira/{cloud_id}/rest/api/3/...`.

  ### Basic auth (CI / headless)
  - `JIRA_HOST`  — Atlassian domain, e.g. `mycompany.atlassian.net`
  - `JIRA_EMAIL` — Atlassian account email
  - `JIRA_TOKEN` — API token from https://id.atlassian.com/manage-profile/security/api-tokens

  ## item_id for `get_item/2`
  Pass the Jira issue key (e.g. `"ENG-123"`).

  ## Options for `list_items/1`
  - `:filter` — JQL query string (default: `"project IS NOT EMPTY AND statusCategory != Done ORDER BY updated DESC"`)
  """

  @behaviour Codrift.Integration

  alias Codrift.Integration.HTTP
  alias Codrift.Integration.Item

  @default_jql "project IS NOT EMPTY AND statusCategory != Done ORDER BY updated DESC"
  @fields "summary,description,status,assignee,labels,issuetype,priority"

  @impl true
  def name, do: "jira"

  @impl true
  def list_items(opts \\ []) do
    with {:ok, creds} <- credentials() do
      jql = opts[:filter] || @default_jql
      encoded_jql = URI.encode_query(%{jql: jql, fields: @fields, maxResults: 50})
      url = "#{api_base(creds)}/search?#{encoded_jql}"

      case HTTP.get(url, auth_headers(creds)) do
        {:ok, %{"issues" => issues}} ->
          {:ok, Enum.map(issues, &to_item(&1, browse_base(creds)))}

        {:ok, _} ->
          {:error, "unexpected response from Jira search API"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def get_item(issue_key, _opts \\ []) do
    with {:ok, creds} <- credentials() do
      url = "#{api_base(creds)}/issue/#{issue_key}?fields=#{@fields}"

      case HTTP.get(url, auth_headers(creds)) do
        {:ok, issue} -> {:ok, to_item(issue, browse_base(creds))}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def to_initiative_context(%Item{} = item) do
    """
    # #{item.title}

    **Source:** Jira — #{item.url}
    **Status:** #{item.status || "unknown"}
    **Assignee:** #{item.assignee || "unassigned"}
    **Labels:** #{format_list(item.labels)}

    ## Description

    #{item.description || "_No description provided._"}
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp to_item(issue, browse_base) do
    fields = issue["fields"] || %{}
    key = issue["key"] || ""

    %Item{
      id: key,
      title: fields["summary"] || "(untitled)",
      description: extract_description(fields["description"]),
      url: "#{browse_base}/browse/#{key}",
      labels: fields["labels"] || [],
      status: get_in(fields, ["status", "name"]),
      assignee: get_in(fields, ["assignee", "displayName"]),
      linked_prs: []
    }
  end

  defp extract_description(nil), do: nil

  defp extract_description(%{"content" => content}) do
    content
    |> Enum.map_join("\n", &extract_paragraph/1)
    |> String.trim()
  end

  defp extract_description(text) when is_binary(text), do: text

  defp extract_paragraph(%{"content" => paragraphs}) do
    Enum.map_join(paragraphs, "", fn
      %{"text" => text} -> text
      _ -> ""
    end)
  end

  defp extract_paragraph(_), do: ""

  defp credentials do
    if Codrift.OAuth.connected?(name()) do
      case Codrift.OAuth.get_token(name()) do
        {:ok, %{"access_token" => t, "cloud_id" => cid, "cloud_site_url" => url}} ->
          {:ok, %{mode: :oauth, token: t, cloud_id: cid, site_url: url}}

        {:ok, _} ->
          {:error,
           "Jira OAuth token is missing cloudId — please re-authorize: codrift integration auth jira"}
      end
    else
      host = System.get_env("JIRA_HOST")
      email = System.get_env("JIRA_EMAIL")
      token = System.get_env("JIRA_TOKEN")

      cond do
        is_nil(host) ->
          {:error, "JIRA_HOST env var is required (e.g. mycompany.atlassian.net)"}

        is_nil(email) ->
          {:error, "JIRA_EMAIL env var is required (or run: codrift integration auth jira)"}

        is_nil(token) ->
          {:error, "JIRA_TOKEN env var is required (or run: codrift integration auth jira)"}

        true ->
          {:ok, %{mode: :basic, host: host, email: email, token: token}}
      end
    end
  end

  defp api_base(%{mode: :oauth, cloud_id: cid}),
    do: "https://api.atlassian.com/ex/jira/#{cid}/rest/api/3"

  defp api_base(%{mode: :basic, host: host}),
    do: "https://#{host}/rest/api/3"

  defp browse_base(%{mode: :oauth, site_url: url}), do: url
  defp browse_base(%{mode: :basic, host: host}), do: "https://#{host}"

  defp auth_headers(%{mode: :oauth, token: t}) do
    [{"authorization", "Bearer #{t}"}, {"accept", "application/json"}]
  end

  defp auth_headers(%{mode: :basic, email: email, token: token}) do
    encoded = Base.encode64("#{email}:#{token}")
    [{"authorization", "Basic #{encoded}"}, {"accept", "application/json"}]
  end

  defp format_list([]), do: "none"
  defp format_list(items), do: Enum.join(items, ", ")
end

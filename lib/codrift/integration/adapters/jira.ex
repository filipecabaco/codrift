defmodule Codrift.Integration.Adapters.Jira do
  @moduledoc """
  Jira Cloud integration adapter (REST API v3).

  ## Environment variables
  - `JIRA_HOST` — Atlassian domain, e.g. `mycompany.atlassian.net`
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
      url = "#{base_url(creds.host)}/search?#{encoded_jql}"

      case HTTP.get(url, auth_headers(creds)) do
        {:ok, %{"issues" => issues}} ->
          {:ok, Enum.map(issues, &to_item/1)}

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
      url = "#{base_url(creds.host)}/issue/#{issue_key}?fields=#{@fields}"

      case HTTP.get(url, auth_headers(creds)) do
        {:ok, issue} -> {:ok, to_item(issue)}
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

  defp to_item(issue) do
    fields = issue["fields"] || %{}
    key = issue["key"] || ""
    host = System.get_env("JIRA_HOST") || ""

    %Item{
      id: key,
      title: fields["summary"] || "(untitled)",
      description: extract_description(fields["description"]),
      url: "https://#{host}/browse/#{key}",
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
    host = System.get_env("JIRA_HOST")
    email = System.get_env("JIRA_EMAIL")
    token = System.get_env("JIRA_TOKEN")

    cond do
      is_nil(host) -> {:error, "JIRA_HOST env var is required"}
      is_nil(email) -> {:error, "JIRA_EMAIL env var is required"}
      is_nil(token) -> {:error, "JIRA_TOKEN env var is required"}
      true -> {:ok, %{host: host, email: email, token: token}}
    end
  end

  defp base_url(host), do: "https://#{host}/rest/api/3"

  defp auth_headers(%{email: email, token: token}) do
    encoded = Base.encode64("#{email}:#{token}")
    [{"authorization", "Basic #{encoded}"}, {"accept", "application/json"}]
  end

  defp format_list([]), do: "none"
  defp format_list(items), do: Enum.join(items, ", ")
end

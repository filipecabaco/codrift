defmodule Codrift.Integration.Adapters.Linear do
  @moduledoc """
  Linear Issues integration adapter (GraphQL).

  ## Environment variables
  - `LINEAR_API_KEY` — Linear personal API key (required)

  ## item_id for `get_item/2`
  Pass the Linear issue ID string (e.g. `"ENG-123"` identifier or the UUID).

  ## Options for `list_items/1`
  - `:filter` — team key string to filter by (e.g. `"ENG"`), or omit for all
  """

  @behaviour Codrift.Integration

  alias Codrift.Integration.Error
  alias Codrift.Integration.HTTP
  alias Codrift.Integration.Item

  import Codrift.Integration, only: [format_list: 1]

  @graphql_url "https://api.linear.app/graphql"

  @impl true
  def name, do: "linear"

  @impl true
  def credentials?,
    do: Codrift.OAuth.connected?(name()) or System.get_env("LINEAR_API_KEY") != nil

  @impl true
  def list_items(opts \\ []) do
    query_issues(build_filter(opts[:filter]))
  end

  @impl true
  def list_assigned(_opts \\ []) do
    open = %{state: %{type: %{nin: ["completed", "canceled"]}}}

    Codrift.Integration.merge_sources([
      {"assigned", query_issues(Map.put(open, :assignee, %{isMe: %{eq: true}}))},
      {"created", query_issues(Map.put(open, :creator, %{isMe: %{eq: true}}))}
    ])
  end

  @impl true
  def get_item(item_id, _opts \\ []) do
    with {:ok, headers} <- auth() do
      query = """
      query GetIssue($id: String!) {
        issue(id: $id) {
          id identifier title description url
          state { name }
          assignee { name }
          labels { nodes { name } }
        }
      }
      """

      case HTTP.graphql(@graphql_url, query, %{id: item_id}, headers) do
        {:ok, %{"data" => %{"issue" => issue}}} when not is_nil(issue) ->
          {:ok, to_item(issue)}

        {:ok, %{"errors" => errors}} ->
          {:error, format_gql_errors(errors)}

        {:ok, _} ->
          {:error, "issue not found: #{item_id}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def to_initiative_context(%Item{} = item) do
    """
    # #{item.title}

    **Source:** Linear — #{item.url}
    **Status:** #{item.status || "unknown"}
    **Assignee:** #{item.assignee || "unassigned"}
    **Labels:** #{format_list(item.labels)}

    ## Description

    #{item.description || "_No description provided._"}
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp query_issues(filter) do
    with {:ok, headers} <- auth() do
      query = """
      query IssueList($filter: IssueFilter) {
        issues(filter: $filter, first: 50, orderBy: updatedAt) {
          nodes {
            id
            identifier
            title
            description
            url
            state { name }
            assignee { name }
            labels { nodes { name } }
          }
        }
      }
      """

      vars = if filter, do: %{filter: filter}, else: %{}

      case HTTP.graphql(@graphql_url, query, vars, headers) do
        {:ok, %{"data" => %{"issues" => %{"nodes" => nodes}}}} ->
          {:ok, Enum.map(nodes, &to_item/1)}

        {:ok, %{"errors" => errors}} ->
          {:error, format_gql_errors(errors)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp to_item(issue) do
    %Item{
      id: issue["identifier"] || issue["id"],
      title: issue["title"] || "(untitled)",
      description: Item.presence(issue["description"]),
      url: issue["url"] || "",
      labels: Enum.map(get_in(issue, ["labels", "nodes"]) || [], & &1["name"]),
      status: get_in(issue, ["state", "name"]),
      assignee: get_in(issue, ["assignee", "name"]),
      linked_prs: []
    }
  end

  defp build_filter(nil), do: nil
  defp build_filter(team_key), do: %{team: %{key: %{eq: team_key}}}

  # `access_token/1` rather than `get_token/1`: the stored token is only 24 hours
  # old at best, and this is the call that renews it. See `Codrift.OAuth`.
  defp auth do
    case Codrift.OAuth.access_token(name()) do
      {:ok, token} ->
        {:ok, [{"authorization", "Bearer #{token}"}]}

      # The grant is spent and cannot be refreshed. An env-var key, if the user
      # has one, is still perfectly good — only fall through to "reconnect" when
      # there is nothing else to try.
      {:error, :reauth_required} ->
        env_auth() || {:error, Error.reauth(name())}

      {:error, :not_found} ->
        env_auth() ||
          {:error, Error.new(:auth, "LINEAR_API_KEY env var is required", service: name())}
    end
  end

  defp env_auth do
    case System.get_env("LINEAR_API_KEY") do
      nil -> nil
      key -> {:ok, [{"authorization", key}]}
    end
  end

  defp format_gql_errors(errors), do: Error.from_graphql(errors, name())
end

defmodule Codrift.Integration.Adapters.GitHubProjects do
  @moduledoc """
  GitHub Projects v2 integration adapter (GraphQL).

  ## Environment variables
  - `GITHUB_TOKEN` — Personal access token with `project` scope (required)
  - `GITHUB_OWNER` — Default owner login (user or org)

  ## item_id for `get_item/2`
  Pass the node ID of a project item (from `list_items/1`).
  For `list_items/1`, pass `filter: "owner/project_number"`, e.g. `"acme/5"`.
  """

  @behaviour Codrift.Integration

  alias Codrift.Integration.HTTP
  alias Codrift.Integration.Item

  @graphql_url "https://api.github.com/graphql"

  @impl true
  def name, do: "github_projects"

  @impl true
  def list_items(opts \\ []) do
    token = System.get_env("GITHUB_TOKEN")

    if token do
      filter = opts[:filter] || ""
      {owner, project_number} = parse_project_filter(filter, opts)
      headers = auth_headers(token)

      user_query = """
      query ListProjectItems($owner: String!, $number: Int!, $first: Int) {
        user(login: $owner) {
          projectV2(number: $number) {
            items(first: $first) {
              nodes {
                id
                content {
                  ... on Issue {
                    number title body url state
                    assignees(first: 3) { nodes { login } }
                    labels(first: 10)  { nodes { name } }
                  }
                  ... on PullRequest {
                    number title body url state
                    assignees(first: 3) { nodes { login } }
                  }
                }
              }
            }
          }
        }
      }
      """

      org_query = """
      query ListOrgProjectItems($owner: String!, $number: Int!, $first: Int) {
        organization(login: $owner) {
          projectV2(number: $number) {
            items(first: $first) {
              nodes {
                id
                content {
                  ... on Issue {
                    number title body url state
                    assignees(first: 3) { nodes { login } }
                    labels(first: 10)  { nodes { name } }
                  }
                  ... on PullRequest {
                    number title body url state
                    assignees(first: 3) { nodes { login } }
                  }
                }
              }
            }
          }
        }
      }
      """

      vars = %{owner: owner, number: project_number, first: 50}

      with {:ok, data} <- run_project_query(user_query, org_query, vars, headers) do
        nodes =
          data |> Enum.map(& &1["content"]) |> Enum.reject(&is_nil/1) |> Enum.map(&to_item/1)

        {:ok, nodes}
      end
    else
      {:error, "GITHUB_TOKEN env var is required for GitHub Projects"}
    end
  end

  @impl true
  def get_item(item_id, _opts \\ []) do
    token = System.get_env("GITHUB_TOKEN")

    if token do
      query = """
      query GetProjectItem($id: ID!) {
        node(id: $id) {
          ... on ProjectV2Item {
            id
            content {
              ... on Issue {
                number title body url state
                assignees(first: 3) { nodes { login } }
                labels(first: 10)  { nodes { name } }
              }
              ... on PullRequest {
                number title body url state
                assignees(first: 3) { nodes { login } }
              }
            }
          }
        }
      }
      """

      case HTTP.graphql(@graphql_url, query, %{id: item_id}, auth_headers(token)) do
        {:ok, %{"data" => %{"node" => %{"content" => content}}}} when not is_nil(content) ->
          {:ok, to_item(content)}

        {:ok, %{"errors" => errors}} ->
          {:error, format_gql_errors(errors)}

        {:ok, _} ->
          {:error, "item not found or not a project item: #{item_id}"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "GITHUB_TOKEN env var is required for GitHub Projects"}
    end
  end

  @impl true
  def to_initiative_context(%Item{} = item) do
    """
    # #{item.title}

    **Source:** GitHub Projects — #{item.url}
    **Status:** #{item.status || "unknown"}
    **Assignee:** #{item.assignee || "unassigned"}
    **Labels:** #{format_list(item.labels)}

    ## Description

    #{item.description || "_No description provided._"}
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp to_item(content) do
    %Item{
      id: to_string(content["number"] || content["id"] || ""),
      title: content["title"] || "(untitled)",
      description: content["body"],
      url: content["url"] || "",
      labels: Enum.map(get_in(content, ["labels", "nodes"]) || [], & &1["name"]),
      status: content["state"],
      assignee:
        case get_in(content, ["assignees", "nodes"]) do
          [first | _] -> first["login"]
          _ -> nil
        end,
      linked_prs: []
    }
  end

  defp parse_project_filter(filter, opts) do
    case String.split(filter, "/", parts: 2) do
      [owner, number_str] ->
        {number, _} = Integer.parse(number_str)
        {owner, number}

      _ ->
        owner = opts[:owner] || System.get_env("GITHUB_OWNER") || ""
        number = opts[:project_number] || 1
        {owner, number}
    end
  end

  defp run_project_query(user_query, org_query, vars, headers) do
    case HTTP.graphql(@graphql_url, user_query, vars, headers) do
      {:ok, %{"data" => data}} ->
        user_nodes = get_in(data, ["user", "projectV2", "items", "nodes"])
        if user_nodes, do: {:ok, user_nodes}, else: run_org_query(org_query, vars, headers)

      {:ok, %{"errors" => errors}} ->
        {:error, format_gql_errors(errors)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_org_query(org_query, vars, headers) do
    case HTTP.graphql(@graphql_url, org_query, vars, headers) do
      {:ok, %{"data" => org_data}} ->
        {:ok, get_in(org_data, ["organization", "projectV2", "items", "nodes"]) || []}

      {:ok, %{"errors" => errors}} ->
        {:error, format_gql_errors(errors)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_headers(env_token) do
    token =
      case Codrift.OAuth.get_token(name()) do
        {:ok, %{"access_token" => t}} ->
          t

        _ ->
          case Codrift.OAuth.get_token("github") do
            {:ok, %{"access_token" => t}} -> t
            _ -> env_token
          end
      end

    [{"authorization", "Bearer #{token}"}]
  end

  defp format_gql_errors(errors) do
    Enum.map_join(errors, "; ", & &1["message"])
  end

  defp format_list([]), do: "none"
  defp format_list(items), do: Enum.join(items, ", ")
end

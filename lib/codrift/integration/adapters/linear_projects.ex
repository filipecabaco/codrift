defmodule Codrift.Integration.Adapters.LinearProjects do
  @moduledoc """
  Linear Projects integration adapter (GraphQL).

  Imports a Linear Project as a multi-context initiative. The project's linked
  issues are summarised in the context file.

  ## Environment variables
  - `LINEAR_API_KEY` — Linear personal API key (required)

  ## item_id for `get_item/2`
  Pass the Linear Project UUID (visible in the project URL).
  """

  @behaviour Codrift.Integration

  alias Codrift.Integration.HTTP
  alias Codrift.Integration.Item

  @graphql_url "https://api.linear.app/graphql"

  @impl true
  def name, do: "linear_projects"

  @impl true
  def list_items(_opts \\ []) do
    case api_key() do
      {:error, _} = err ->
        err

      {:ok, key} ->
        query = """
        query ListProjects {
          projects(first: 50, orderBy: updatedAt) {
            nodes {
              id
              name
              description
              url
              state
              progress
              teams { nodes { name key } }
              issues(first: 5) { nodes { identifier title } }
            }
          }
        }
        """

        case HTTP.graphql(@graphql_url, query, %{}, auth_headers(key)) do
          {:ok, %{"data" => %{"projects" => %{"nodes" => nodes}}}} ->
            {:ok, Enum.map(nodes, &project_to_item/1)}

          {:ok, %{"errors" => errors}} ->
            {:error, format_gql_errors(errors)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def get_item(project_id, _opts \\ []) do
    case api_key() do
      {:error, _} = err ->
        err

      {:ok, key} ->
        query = """
        query GetProject($id: String!) {
          project(id: $id) {
            id name description url state progress
            teams { nodes { name key } }
            issues(first: 50, orderBy: updatedAt) {
              nodes {
                identifier title state { name }
                assignee { name }
              }
            }
          }
        }
        """

        case HTTP.graphql(@graphql_url, query, %{id: project_id}, auth_headers(key)) do
          {:ok, %{"data" => %{"project" => project}}} when not is_nil(project) ->
            {:ok, project_to_item(project)}

          {:ok, %{"errors" => errors}} ->
            {:error, format_gql_errors(errors)}

          {:ok, _} ->
            {:error, "project not found: #{project_id}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def to_initiative_context(%Item{} = item) do
    issue_lines =
      case item.linked_prs do
        [] ->
          "_No issues linked._"

        issues ->
          Enum.map_join(issues, "\n", &"- #{&1}")
      end

    """
    # #{item.title}

    **Source:** Linear Project — #{item.url}
    **Status:** #{item.status || "unknown"}
    **Progress:** #{item.assignee || "0%"}

    ## Description

    #{item.description || "_No description provided._"}

    ## Issues

    #{issue_lines}
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp project_to_item(project) do
    teams = Enum.map(get_in(project, ["teams", "nodes"]) || [], & &1["key"])
    issues = Enum.map(get_in(project, ["issues", "nodes"]) || [], &"#{&1["identifier"]} #{&1["title"]}")
    progress = format_progress(project["progress"])

    %Item{
      id: project["id"],
      title: project["name"] || "(untitled)",
      description: project["description"],
      url: project["url"] || "",
      labels: teams,
      status: project["state"],
      assignee: progress,
      linked_prs: issues
    }
  end

  defp format_progress(nil), do: "0%"
  defp format_progress(p) when is_float(p), do: "#{round(p * 100)}%"
  defp format_progress(p), do: "#{p}%"

  defp api_key do
    case System.get_env("LINEAR_API_KEY") do
      nil -> {:error, "LINEAR_API_KEY env var is required"}
      key -> {:ok, key}
    end
  end

  defp auth_headers(env_key) do
    case Codrift.OAuth.get_token(name()) do
      {:ok, %{"access_token" => t}} -> [{"authorization", "Bearer #{t}"}]
      _ -> [{"authorization", env_key}]
    end
  end

  defp format_gql_errors(errors) do
    errors |> Enum.map(& &1["message"]) |> Enum.join("; ")
  end
end

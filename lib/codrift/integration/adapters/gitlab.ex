defmodule Codrift.Integration.Adapters.GitLab do
  @moduledoc """
  GitLab Issues integration adapter (REST API v4).

  ## Environment variables
  - `GITLAB_TOKEN` — GitLab personal access token or project token
  - `GITLAB_HOST` — GitLab hostname (default: `gitlab.com`)
  - `GITLAB_PROJECT` — URL-encoded project path (e.g. `"mygroup%2Fmyrepo"`)

  ## item_id for `get_item/2`
  Pass `"project_path#issue_iid"` (e.g. `"mygroup/myrepo#42"`) or just the
  issue IID number (requires `:project` option or `GITLAB_PROJECT`).
  """

  @behaviour Codrift.Integration

  alias Codrift.Integration.HTTP
  alias Codrift.Integration.Item

  @impl true
  def name, do: "gitlab"

  @impl true
  def list_items(opts \\ []) do
    with {:ok, project} <- resolve_project(opts),
         {:ok, token} <- require_token() do
      state = opts[:filter] || "opened"
      encoded = URI.encode_www_form(project)
      url = "#{base_url()}/projects/#{encoded}/issues?state=#{state}&per_page=50"

      case HTTP.get(url, auth_headers(token)) do
        {:ok, issues} when is_list(issues) -> {:ok, Enum.map(issues, &to_item/1)}
        {:ok, _} -> {:error, "unexpected response from GitLab Issues API"}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def get_item(item_id, opts \\ []) do
    with {:ok, token} <- require_token(),
         {:ok, {project, iid}} <- parse_item_id(item_id, opts) do
      encoded = URI.encode_www_form(project)
      url = "#{base_url()}/projects/#{encoded}/issues/#{iid}"

      case HTTP.get(url, auth_headers(token)) do
        {:ok, issue} -> {:ok, to_item(issue)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def to_initiative_context(%Item{} = item) do
    """
    # #{item.title}

    **Source:** GitLab Issue — #{item.url}
    **Status:** #{item.status || "opened"}
    **Assignee:** #{item.assignee || "unassigned"}
    **Labels:** #{format_list(item.labels)}

    ## Description

    #{item.description || "_No description provided._"}
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp to_item(issue) do
    %Item{
      id: to_string(issue["iid"]),
      title: issue["title"] || "(untitled)",
      description: issue["description"],
      url: issue["web_url"] || "",
      labels: issue["labels"] || [],
      status: issue["state"],
      assignee: get_in(issue, ["assignee", "name"]),
      linked_prs: []
    }
  end

  defp parse_item_id(item_id, opts) do
    cond do
      String.contains?(item_id, "#") ->
        case String.split(item_id, "#", parts: 2) do
          [project, iid] -> {:ok, {project, iid}}
          _ -> {:error, "invalid item_id format: #{item_id}"}
        end

      true ->
        case resolve_project(opts) do
          {:ok, project} -> {:ok, {project, item_id}}
          {:error, _} = err -> err
        end
    end
  end

  defp resolve_project(opts) do
    case opts[:project] || System.get_env("GITLAB_PROJECT") do
      nil -> {:error, "GITLAB_PROJECT env var or :project option is required"}
      project -> {:ok, project}
    end
  end

  defp require_token do
    case System.get_env("GITLAB_TOKEN") do
      nil -> {:error, "GITLAB_TOKEN env var is required"}
      token -> {:ok, token}
    end
  end

  defp base_url do
    host = System.get_env("GITLAB_HOST") || "gitlab.com"
    "https://#{host}/api/v4"
  end

  defp auth_headers(token), do: [{"private-token", token}]

  defp format_list([]), do: "none"
  defp format_list(items), do: Enum.join(items, ", ")
end

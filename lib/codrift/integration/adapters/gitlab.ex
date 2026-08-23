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

  alias Codrift.Integration.Error
  alias Codrift.Integration.HTTP
  alias Codrift.Integration.Item

  @impl true
  def name, do: "gitlab"

  @impl true
  def credentials?, do: Codrift.OAuth.connected?(name()) or System.get_env("GITLAB_TOKEN") != nil

  @impl true
  def list_items(opts \\ []) do
    with {:ok, project} <- resolve_project(opts),
         {:ok, headers} <- auth() do
      state = opts[:filter] || "opened"
      encoded = URI.encode_www_form(project)

      get_issues("#{base_url()}/projects/#{encoded}/issues?state=#{state}&per_page=50", headers)
    end
  end

  @impl true
  def list_assigned(opts \\ []) do
    with {:ok, headers} <- auth() do
      state = opts[:filter] || "opened"

      Codrift.Integration.merge_sources([
        {"assigned", my_issues("assigned_to_me", state, headers)},
        {"created", my_issues("created_by_me", state, headers)}
      ])
    end
  end

  @impl true
  def get_item(item_id, opts \\ []) do
    with {:ok, headers} <- auth(),
         {:ok, {project, iid}} <- parse_item_id(item_id, opts) do
      encoded = URI.encode_www_form(project)
      url = "#{base_url()}/projects/#{encoded}/issues/#{iid}"

      case HTTP.get(url, headers) do
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

  defp my_issues(scope, state, headers) do
    get_issues(
      "#{base_url()}/issues?scope=#{scope}&state=#{state}&order_by=updated_at&per_page=50",
      headers
    )
  end

  defp get_issues(url, headers) do
    case HTTP.get(url, headers) do
      {:ok, issues} when is_list(issues) -> {:ok, Enum.map(issues, &to_item/1)}
      {:ok, _} -> {:error, "unexpected response from GitLab Issues API"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_item(issue) do
    %Item{
      id: qualified_id(issue),
      title: issue["title"] || "(untitled)",
      description: Item.presence(issue["description"]),
      url: issue["web_url"] || "",
      labels: issue["labels"] || [],
      status: issue["state"],
      assignee: get_in(issue, ["assignee", "name"]),
      linked_prs: []
    }
  end

  defp qualified_id(issue) do
    case get_in(issue, ["references", "full"]) do
      "" <> ref -> if String.contains?(ref, "#"), do: ref, else: to_string(issue["iid"])
      _ -> to_string(issue["iid"])
    end
  end

  defp parse_item_id(item_id, opts) do
    if String.contains?(item_id, "#") do
      case String.split(item_id, "#", parts: 2) do
        [project, iid] -> {:ok, {project, iid}}
        _ -> {:error, "invalid item_id format: #{item_id}"}
      end
    else
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
          {:error, Error.new(:auth, "GITLAB_TOKEN env var is required", service: name())}
    end
  end

  defp env_auth do
    case System.get_env("GITLAB_TOKEN") do
      nil -> nil
      token -> {:ok, [{"private-token", token}]}
    end
  end

  defp base_url do
    host = System.get_env("GITLAB_HOST") || "gitlab.com"
    "https://#{host}/api/v4"
  end

  defp format_list([]), do: "none"
  defp format_list(items), do: Enum.join(items, ", ")
end

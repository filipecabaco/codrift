defmodule Codrift.Integration.Adapters.GitHub do
  @moduledoc """
  GitHub Issues integration adapter.

  ## Environment variables
  - `GITHUB_TOKEN` — Personal access token or fine-grained PAT (public repos work without one)
  - `GITHUB_REPO` — Default repo in `owner/repo` format

  ## item_id formats accepted by `get_item/2`
  - `"owner/repo#123"` — fully qualified
  - `"123"` — number only (requires `:repo` option or `GITHUB_REPO`)
  """

  @behaviour Codrift.Integration

  alias Codrift.Integration.HTTP
  alias Codrift.Integration.Item

  @base "https://api.github.com"

  @impl true
  def name, do: "github"

  @impl true
  def credentials?, do: Codrift.OAuth.connected?(name()) or System.get_env("GITHUB_TOKEN") != nil

  @impl true
  def list_assigned(opts \\ []) do
    state = opts[:filter] || "open"

    Codrift.Integration.merge_sources([
      {"assigned", my_issues("assigned", state)},
      {"created", my_issues("created", state)}
    ])
  end

  @impl true
  def list_items(opts \\ []) do
    case resolve_repo(opts) do
      {:error, _} = err ->
        err

      {:ok, repo} ->
        state = opts[:filter] || "open"
        url = "#{@base}/repos/#{repo}/issues?state=#{state}&per_page=50"

        case HTTP.get(url, auth_headers()) do
          {:ok, issues} when is_list(issues) ->
            {:ok, to_issue_items(issues)}

          {:ok, _} ->
            {:error, "unexpected response from GitHub Issues API"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def get_item(item_id, opts \\ []) do
    with {:ok, {repo, number}} <- parse_item_id(item_id, opts) do
      url = "#{@base}/repos/#{repo}/issues/#{number}"

      case HTTP.get(url, auth_headers()) do
        {:ok, issue} -> {:ok, to_item(issue)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def to_initiative_context(%Item{} = item) do
    """
    # #{item.title}

    **Source:** GitHub Issue — #{item.url}
    **Status:** #{item.status || "open"}
    **Assignee:** #{item.assignee || "unassigned"}
    **Labels:** #{format_list(item.labels)}

    ## Description

    #{item.description || "_No description provided._"}
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp my_issues(filter, state) do
    url = "#{@base}/issues?filter=#{filter}&state=#{state}&sort=updated&per_page=50"

    case HTTP.get(url, auth_headers()) do
      {:ok, issues} when is_list(issues) -> {:ok, to_issue_items(issues)}
      {:ok, _} -> {:error, "unexpected response from GitHub Issues API"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_issue_items(issues) do
    issues |> Enum.reject(&Map.has_key?(&1, "pull_request")) |> Enum.map(&to_item/1)
  end

  defp to_item(issue) do
    %Item{
      id: qualified_id(issue),
      title: issue["title"] || "(untitled)",
      description: Item.presence(issue["body"]),
      url: issue["html_url"],
      labels: Enum.map(issue["labels"] || [], & &1["name"]),
      status: issue["state"],
      assignee: get_in(issue, ["assignee", "login"]),
      linked_prs: []
    }
  end

  defp qualified_id(issue) do
    number = to_string(issue["number"])

    case repo_of(issue) do
      nil -> number
      repo -> "#{repo}##{number}"
    end
  end

  defp repo_of(%{"repository" => %{"full_name" => full_name}}) when is_binary(full_name),
    do: full_name

  defp repo_of(%{"repository_url" => url}) when is_binary(url) do
    case String.split(url, "/repos/", parts: 2) do
      [_, repo] -> repo
      _ -> nil
    end
  end

  defp repo_of(_issue), do: nil

  defp parse_item_id(item_id, opts) do
    if String.contains?(item_id, "#") do
      case String.split(item_id, "#", parts: 2) do
        [repo, number] -> {:ok, {repo, number}}
        _ -> {:error, "invalid item_id format: #{item_id}"}
      end
    else
      case resolve_repo(opts) do
        {:ok, repo} -> {:ok, {repo, item_id}}
        {:error, _} = err -> err
      end
    end
  end

  defp resolve_repo(opts) do
    case opts[:repo] || System.get_env("GITHUB_REPO") do
      nil -> {:error, "GITHUB_REPO env var or :repo option is required"}
      repo -> {:ok, repo}
    end
  end

  defp auth_headers do
    base = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

    token =
      case Codrift.OAuth.get_token(name()) do
        {:ok, %{"access_token" => t}} -> t
        _ -> System.get_env("GITHUB_TOKEN")
      end

    if token, do: [{"authorization", "Bearer #{token}"} | base], else: base
  end

  defp format_list([]), do: "none"
  defp format_list(items), do: Enum.join(items, ", ")
end

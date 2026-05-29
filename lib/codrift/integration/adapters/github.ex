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
  def list_items(opts \\ []) do
    case resolve_repo(opts) do
      {:error, _} = err ->
        err

      {:ok, repo} ->
        state = opts[:filter] || "open"
        url = "#{@base}/repos/#{repo}/issues?state=#{state}&per_page=50"

        case HTTP.get(url, auth_headers()) do
          {:ok, issues} when is_list(issues) ->
            {:ok, issues |> Enum.reject(&Map.has_key?(&1, "pull_request")) |> Enum.map(&to_item/1)}

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

  defp to_item(issue) do
    %Item{
      id: to_string(issue["number"]),
      title: issue["title"] || "(untitled)",
      description: issue["body"],
      url: issue["html_url"],
      labels: Enum.map(issue["labels"] || [], & &1["name"]),
      status: issue["state"],
      assignee: get_in(issue, ["assignee", "login"]),
      linked_prs: []
    }
  end

  defp parse_item_id(item_id, opts) do
    cond do
      String.contains?(item_id, "#") ->
        case String.split(item_id, "#", parts: 2) do
          [repo, number] -> {:ok, {repo, number}}
          _ -> {:error, "invalid item_id format: #{item_id}"}
        end

      true ->
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

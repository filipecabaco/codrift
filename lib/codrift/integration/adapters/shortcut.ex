defmodule Codrift.Integration.Adapters.Shortcut do
  @moduledoc """
  Shortcut (formerly Clubhouse) integration adapter (REST API v3).

  ## Environment variables
  - `SHORTCUT_TOKEN` — Shortcut API token from https://app.shortcut.com/settings/api-tokens

  ## item_id for `get_item/2`
  Pass the story public ID number (e.g. `"1234"`).

  ## Options for `list_items/1`
  - `:filter` — workflow state name to filter by (e.g. `"In Progress"`), or omit for all unarchived
  """

  @behaviour Codrift.Integration

  alias Codrift.Integration.HTTP
  alias Codrift.Integration.Item

  @base "https://api.app.shortcut.com/api/v3"

  @impl true
  def name, do: "shortcut"

  @impl true
  def list_items(opts \\ []) do
    with {:ok, token} <- require_token() do
      filter = opts[:filter]

      query =
        if filter do
          %{query: filter, page_size: 50}
        else
          %{archived: false, page_size: 50}
        end

      url = "#{@base}/stories/search"

      case HTTP.post(url, query, auth_headers(token)) do
        {:ok, %{"data" => stories}} when is_list(stories) ->
          {:ok, Enum.map(stories, &to_item/1)}

        {:ok, stories} when is_list(stories) ->
          {:ok, Enum.map(stories, &to_item/1)}

        {:ok, _} ->
          {:error, "unexpected response from Shortcut search API"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def get_item(story_id, _opts \\ []) do
    with {:ok, token} <- require_token() do
      url = "#{@base}/stories/#{story_id}"

      case HTTP.get(url, auth_headers(token)) do
        {:ok, story} -> {:ok, to_item(story)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def to_initiative_context(%Item{} = item) do
    """
    # #{item.title}

    **Source:** Shortcut Story — #{item.url}
    **Status:** #{item.status || "unknown"}
    **Assignee:** #{item.assignee || "unassigned"}
    **Labels:** #{format_list(item.labels)}

    ## Description

    #{item.description || "_No description provided._"}
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp to_item(story) do
    %Item{
      id: to_string(story["id"]),
      title: story["name"] || "(untitled)",
      description: story["description"],
      url: story["app_url"] || "",
      labels: Enum.map(story["labels"] || [], & &1["name"]),
      status: story["story_type"] || "feature",
      assignee: story |> Map.get("owner_ids", []) |> List.first(),
      linked_prs: []
    }
  end

  defp require_token do
    case System.get_env("SHORTCUT_TOKEN") do
      nil -> {:error, "SHORTCUT_TOKEN env var is required"}
      token -> {:ok, token}
    end
  end

  defp auth_headers(token), do: [{"shortcut-token", token}]

  defp format_list([]), do: "none"
  defp format_list(items), do: Enum.join(items, ", ")
end

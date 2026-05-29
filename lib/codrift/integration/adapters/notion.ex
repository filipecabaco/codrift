defmodule Codrift.Integration.Adapters.Notion do
  @moduledoc """
  Notion integration adapter (Blocks API v1).

  Imports a Notion database row (page) or a standalone page as an initiative.

  ## Environment variables
  - `NOTION_API_KEY` — Notion integration token from https://www.notion.so/my-integrations
  - `NOTION_DATABASE_ID` — Default database ID to query (can be overridden via filter)

  ## item_id for `get_item/2`
  Pass the Notion page ID (32-char UUID, with or without hyphens).

  ## Options for `list_items/1`
  - `:filter` — Database ID to query (overrides `NOTION_DATABASE_ID`)
  """

  @behaviour Codrift.Integration

  alias Codrift.Integration.HTTP
  alias Codrift.Integration.Item

  @base "https://api.notion.com/v1"
  @notion_version "2022-06-28"

  @impl true
  def name, do: "notion"

  @impl true
  def list_items(opts \\ []) do
    with {:ok, token} <- require_token() do
      db_id = opts[:filter] || System.get_env("NOTION_DATABASE_ID")

      unless db_id do
        {:error, "NOTION_DATABASE_ID env var or :filter option (database ID) is required"}
      else
        url = "#{@base}/databases/#{db_id}/query"
        body = %{page_size: 50}

        case HTTP.post(url, body, auth_headers(token)) do
          {:ok, %{"results" => pages}} ->
            {:ok, Enum.map(pages, &to_item/1)}

          {:ok, _} ->
            {:error, "unexpected response from Notion database API"}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @impl true
  def get_item(page_id, _opts \\ []) do
    with {:ok, token} <- require_token() do
      clean_id = String.replace(page_id, "-", "")
      url = "#{@base}/pages/#{clean_id}"

      case HTTP.get(url, auth_headers(token)) do
        {:ok, page} ->
          {:ok, to_item(page)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def to_initiative_context(%Item{} = item) do
    """
    # #{item.title}

    **Source:** Notion — #{item.url}
    **Status:** #{item.status || "unknown"}
    **Assignee:** #{item.assignee || "unassigned"}
    **Labels:** #{format_list(item.labels)}

    ## Description

    #{item.description || "_No description provided._"}
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp to_item(page) do
    props = page["properties"] || %{}
    page_id = page["id"] || ""
    url = get_in(page, ["url"]) || "https://notion.so/#{String.replace(page_id, "-", "")}"

    %Item{
      id: page_id,
      title: extract_title(props),
      description: extract_rich_text(props, "Description") || extract_rich_text(props, "Notes"),
      url: url,
      labels: extract_multi_select(props, "Tags") ++ extract_multi_select(props, "Labels"),
      status: extract_select(props, "Status") || extract_select(props, "Stage"),
      assignee: extract_person(props, "Assignee") || extract_person(props, "Owner"),
      linked_prs: []
    }
  end

  defp extract_title(props) do
    Enum.find_value(props, "(untitled)", fn {_key, val} ->
      case val do
        %{"title" => [%{"plain_text" => text} | _]} when is_binary(text) and text != "" -> text
        _ -> nil
      end
    end)
  end

  defp extract_rich_text(props, key) do
    case get_in(props, [key, "rich_text"]) do
      [%{"plain_text" => text} | _] -> text
      _ -> nil
    end
  end

  defp extract_multi_select(props, key) do
    (get_in(props, [key, "multi_select"]) || []) |> Enum.map(& &1["name"])
  end

  defp extract_select(props, key) do
    get_in(props, [key, "select", "name"])
  end

  defp extract_person(props, key) do
    case get_in(props, [key, "people"]) do
      [%{"name" => name} | _] -> name
      _ -> nil
    end
  end

  defp require_token do
    case Codrift.OAuth.get_token(name()) do
      {:ok, %{"access_token" => t}} ->
        {:ok, t}

      _ ->
        case System.get_env("NOTION_API_KEY") do
          nil -> {:error, "NOTION_API_KEY env var is required (or run: codrift integration auth notion)"}
          token -> {:ok, token}
        end
    end
  end

  defp auth_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"notion-version", @notion_version}
    ]
  end

  defp format_list([]), do: "none"
  defp format_list(items), do: Enum.join(items, ", ")
end

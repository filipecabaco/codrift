defmodule Codrift.Integration.Adapters.Asana do
  @moduledoc """
  Asana integration adapter (REST API v1).

  ## Environment variables
  - `ASANA_ACCESS_TOKEN` — Asana personal access token or OAuth token
  - `ASANA_PROJECT_GID` — Default project GID (can be overridden via `:filter`)

  ## item_id for `get_item/2`
  Pass the Asana task GID (numeric string).

  ## Options for `list_items/1`
  - `:filter` — Asana project GID (overrides `ASANA_PROJECT_GID`)
  """

  @behaviour Codrift.Integration

  alias Codrift.Integration.HTTP
  alias Codrift.Integration.Item

  @base "https://app.asana.com/api/1.0"
  @task_fields "name,notes,permalink_url,completed,assignee.name,tags.name,custom_fields"

  @impl true
  def name, do: "asana"

  @impl true
  def list_items(opts \\ []) do
    with {:ok, token} <- require_token() do
      project_gid = opts[:filter] || System.get_env("ASANA_PROJECT_GID")

      unless project_gid do
        {:error, "ASANA_PROJECT_GID env var or :filter option (project GID) is required"}
      else
        url = "#{@base}/tasks?project=#{project_gid}&opt_fields=#{@task_fields}&limit=100"

        case HTTP.get(url, auth_headers(token)) do
          {:ok, %{"data" => tasks}} when is_list(tasks) ->
            active = Enum.reject(tasks, & &1["completed"])
            {:ok, Enum.map(active, &to_item/1)}

          {:ok, _} ->
            {:error, "unexpected response from Asana Tasks API"}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @impl true
  def get_item(task_gid, _opts \\ []) do
    with {:ok, token} <- require_token() do
      url = "#{@base}/tasks/#{task_gid}?opt_fields=#{@task_fields}"

      case HTTP.get(url, auth_headers(token)) do
        {:ok, %{"data" => task}} -> {:ok, to_item(task)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def to_initiative_context(%Item{} = item) do
    """
    # #{item.title}

    **Source:** Asana Task — #{item.url}
    **Status:** #{item.status || "active"}
    **Assignee:** #{item.assignee || "unassigned"}
    **Tags:** #{format_list(item.labels)}

    ## Description

    #{item.description || "_No description provided._"}
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp to_item(task) do
    tags = Enum.map(task["tags"] || [], & &1["name"])

    custom_status =
      task
      |> Map.get("custom_fields", [])
      |> Enum.find_value(fn cf ->
        if cf["name"] in ["Status", "Stage"] and cf["display_value"], do: cf["display_value"]
      end)

    %Item{
      id: task["gid"] || "",
      title: task["name"] || "(untitled)",
      description: task["notes"],
      url: task["permalink_url"] || "",
      labels: tags,
      status: custom_status || (if task["completed"], do: "completed", else: "active"),
      assignee: get_in(task, ["assignee", "name"]),
      linked_prs: []
    }
  end

  defp require_token do
    case Codrift.OAuth.get_token(name()) do
      {:ok, %{"access_token" => t}} ->
        {:ok, t}

      _ ->
        case System.get_env("ASANA_ACCESS_TOKEN") do
          nil -> {:error, "ASANA_ACCESS_TOKEN env var is required (or run: codrift integration auth asana)"}
          token -> {:ok, token}
        end
    end
  end

  defp auth_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json"}
    ]
  end

  defp format_list([]), do: "none"
  defp format_list(items), do: Enum.join(items, ", ")
end

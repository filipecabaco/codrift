defmodule Codrift.Config.Settings do
  @moduledoc """
  Reads and writes `~/.codrift/settings.json`.

  Tracks per-adapter start counts (used to sort the agent picker) and the
  user's **launch profiles** — named bindings of a base adapter plus env
  overrides, so the same tool can run under different accounts/config folders
  (e.g. `claude-personal` vs `claude-work` via distinct `CLAUDE_CONFIG_DIR`s).

  Profiles are stored under the `"profiles"` key, keyed by name:

      {
        "profiles": {
          "claude-work":     { "adapter": "claude", "env": { "CLAUDE_CONFIG_DIR": "~/.claude-work" } },
          "claude-personal": { "adapter": "claude", "env": { "CLAUDE_CONFIG_DIR": "~/.claude-personal" } }
        }
      }
  """

  defp path, do: Path.join(Codrift.Paths.data_dir(), "settings.json")

  @doc ~S(Returns all launch profiles as `name => %{"adapter" => name, "env" => map}`.)
  def profiles do
    read() |> Map.get("profiles", %{})
  end

  @doc "Fetches one launch profile by name, or `{:error, :not_found}`."
  def profile(name) do
    case Map.fetch(profiles(), name) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, :not_found}
    end
  end

  @doc "Returns a map of adapter name → start count."
  def adapter_start_counts do
    read() |> Map.get("adapter_starts", %{})
  end

  @doc "Increments the start count for the given adapter module."
  def increment_adapter_start(adapter) do
    name = Codrift.Agent.adapter_name(adapter)
    settings = read()
    counts = Map.get(settings, "adapter_starts", %{})
    write(Map.put(settings, "adapter_starts", Map.update(counts, name, 1, &(&1 + 1))))
  end

  defp read do
    case File.read(path()) do
      {:ok, content} -> JSON.decode!(content)
      {:error, _} -> %{}
    end
  end

  defp write(data) do
    path = path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(data))
  end
end

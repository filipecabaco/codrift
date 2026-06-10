defmodule Codrift.Config.Settings do
  @moduledoc """
  Reads and writes `~/.codrift/settings.json`.

  Currently tracks per-adapter start counts used to sort the agent picker by
  most-used adapters.
  """

  @path Path.expand("~/.codrift/settings.json")

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
    case File.read(@path) do
      {:ok, content} -> JSON.decode!(content)
      {:error, _} -> %{}
    end
  end

  defp write(data) do
    File.mkdir_p!(Path.dirname(@path))
    File.write!(@path, JSON.encode!(data))
  end
end

defmodule Codrift.Integration.Sync do
  @moduledoc """
  Polls each initiative that was imported from an external service and
  updates its Codrift status to match the remote item's status.

  Called by `Codrift.Scheduler` every 5 minutes. Errors for individual
  initiatives are logged and skipped — one failing integration never
  blocks the others.
  """

  require Logger

  alias Codrift.Initiative.Store
  alias Codrift.Integration

  @doc "Syncs all integration-linked initiatives. Safe to call manually."
  def run(store \\ Store) do
    store
    |> Store.list()
    |> Enum.filter(& &1.integration)
    |> Enum.each(&sync_one(&1, store))
  end

  defp sync_one(initiative, store) do
    %{service: service, item_id: item_id} = initiative.integration

    with {:ok, adapter} <- Integration.adapter_for(service),
         {:ok, item} <- adapter.get_item(item_id, []) do
      new_status = Integration.map_item_status(item.status)
      context = adapter.to_initiative_context(item)

      if new_status != initiative.status do
        Logger.info("Integration sync: #{initiative.id} #{service}/#{item_id} → #{new_status}")
        Store.set_status(initiative.id, new_status, store)
        Integration.write_integration_files(initiative.id, service, item_id, context)
      end
    else
      {:error, reason} ->
        Logger.warning(
          "Integration sync failed for #{initiative.id} (#{service}/#{item_id}): #{inspect(reason)}"
        )
    end
  end
end

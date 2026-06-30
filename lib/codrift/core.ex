defmodule Codrift.Core do
  @moduledoc """
  Shared operation layer behind every Codrift surface.

  The MCP server (`Codrift.MCP.Handler`), the HTTP/JSON API (`POST /api/rpc`),
  and the web UI all route through `call/2`. Each operation takes a name and a
  string-keyed argument map and returns `{:ok, result}` or `{:error, message}`.

  This is the single source of truth for what the product can *do*; the
  transports above it only translate envelopes (JSON-RPC, REST, WebSocket).
  """

  alias Codrift.Initiative.{DirEntry, Store}
  alias Codrift.OAuth.Config, as: OAuthConfig

  @doc """
  Invokes a named operation with a string-keyed argument map.

  Returns `{:ok, result}` on success or `{:error, message}` on failure or
  for unknown operations.
  """
  def call("list_initiatives", _args) do
    {:ok, Enum.map(Store.list(), &initiative_map/1)}
  end

  # Lets a folderless ("scratch") initiative use its own context folder as the
  # working directory — so agents, tree, diff and the editor all operate there.
  # Deleting the initiative removes the folder, matching the throwaway workflow.
  def call("add_context_workspace", %{"initiative_id" => id}) do
    case Store.add_dir(id, Store.context_path(id)) do
      {:ok, initiative} -> {:ok, initiative_map(initiative)}
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
    end
  end

  def call("get_diff", %{"initiative_id" => initiative_id}) do
    case Store.get(initiative_id) do
      {:ok, initiative} ->
        {:ok,
         Enum.flat_map(initiative.dirs, fn entry -> dir_diffs(DirEntry.effective_path(entry)) end)}

      {:error, :not_found} ->
        {:error, "initiative not found: #{initiative_id}"}
    end
  end

  def call("list_agents", _args) do
    agents =
      Enum.map(Codrift.AgentSupervisor.list_agents(), fn pid ->
        pid
        |> Codrift.AgentProcess.status()
        |> Map.update!(:adapter, &Codrift.Agent.adapter_name/1)
        |> Map.update!(:status, &Atom.to_string/1)
      end)

    {:ok, agents}
  end

  def call("get_initiative_agents", %{"initiative_id" => initiative_id}) do
    agents =
      initiative_id
      |> Codrift.AgentSupervisor.list_agents_for_initiative()
      |> Enum.map(fn pid ->
        pid
        |> Codrift.AgentProcess.status()
        |> Map.update!(:adapter, &Codrift.Agent.adapter_name/1)
        |> Map.update!(:status, &Atom.to_string/1)
      end)

    {:ok, agents}
  end

  def call("broadcast_to_initiative", %{"initiative_id" => initiative_id, "input" => input}) do
    case Codrift.AgentSupervisor.list_agents_for_initiative(initiative_id) do
      [] ->
        {:error, "no running agents for initiative: #{initiative_id}"}

      pids ->
        Enum.each(pids, &Codrift.AgentProcess.send_input(&1, input))
        {:ok, %{"sent_to" => length(pids)}}
    end
  end

  def call("start_agent", %{"initiative_id" => init_id, "dir" => dir, "adapter" => adapter}) do
    module = adapter_module(adapter)
    expanded_dir = Path.expand(dir)

    case Codrift.AgentSupervisor.start_agent(init_id, expanded_dir, module) do
      {:ok, pid} ->
        status =
          pid
          |> Codrift.AgentProcess.status()
          |> Map.update!(:adapter, &Codrift.Agent.adapter_name/1)
          |> Map.update!(:status, &Atom.to_string/1)

        {:ok, status}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def call("send_to_agent", %{"agent_id" => agent_id, "input" => input}) do
    case Codrift.AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} ->
        Codrift.AgentProcess.send_input(pid, input)
        {:ok, %{"ok" => true}}

      {:error, :not_found} ->
        {:error, "agent not found: #{agent_id}"}
    end
  end

  def call("stop_agent", %{"agent_id" => agent_id}) do
    case Codrift.AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} ->
        Codrift.AgentSupervisor.stop_agent(pid)
        {:ok, %{"stopped" => agent_id}}

      {:error, :not_found} ->
        {:error, "agent not found: #{agent_id}"}
    end
  end

  def call("get_agent_output", %{"agent_id" => agent_id} = args) do
    n = args["n"] || 50

    case Codrift.AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} -> {:ok, %{"output" => Codrift.AgentProcess.recent_output(pid, n)}}
      {:error, :not_found} -> {:error, "agent not found: #{agent_id}"}
    end
  end

  def call("create_initiative", %{"name" => name} = args) do
    dirs = Map.get(args, "dirs", [])

    case Store.create(name, dirs) do
      {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("add_dir", %{"initiative_id" => id, "dir" => dir}) do
    expanded = Path.expand(dir)

    case Store.add_dir(id, expanded) do
      {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
    end
  end

  def call("delete_initiative", %{"initiative_id" => id}) do
    case Store.delete(id) do
      :ok -> {:ok, %{"deleted" => id}}
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
    end
  end

  def call("set_initiative_status", %{"initiative_id" => id, "status" => status_str}) do
    valid = ~w(planning ongoing done archived)

    if status_str in valid do
      status = String.to_existing_atom(status_str)

      case Store.set_status(id, status) do
        {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
        {:error, :not_found} -> {:error, "initiative not found: #{id}"}
      end
    else
      {:error, "invalid status: #{status_str}. Must be one of: #{Enum.join(valid, ", ")}"}
    end
  end

  def call("memory_search", %{"initiative_id" => id, "query" => query}) do
    {:ok, Codrift.Memory.search(id, query)}
  end

  def call(
        "memory_add",
        %{"initiative_id" => id, "chunk_type" => type, "content" => content} = args
      ) do
    source = Map.get(args, "source", "mcp")
    valid = Codrift.Memory.valid_types()

    if type in valid do
      case Codrift.Memory.add(id, type, content, source) do
        {:ok, rowid} -> {:ok, %{"id" => rowid}}
      end
    else
      {:error, "invalid chunk_type '#{type}'. Must be one of: #{Enum.join(valid, ", ")}"}
    end
  end

  def call("memory_delete", %{"initiative_id" => id, "id" => rowid}) when is_integer(rowid) do
    case Codrift.Memory.delete(id, rowid) do
      :ok -> {:ok, %{"deleted" => rowid}}
      {:error, :not_found} -> {:error, "memory entry not found: #{rowid}"}
    end
  end

  def call("memory_delete", %{"initiative_id" => _id, "id" => rowid}) do
    {:error, "id must be an integer, got: #{inspect(rowid)}"}
  end

  def call("memory_recent", %{"initiative_id" => id} = args) do
    limit = args |> Map.get("limit", 20) |> clamp_limit()
    {:ok, Codrift.Memory.recent(id, limit)}
  end

  def call("memory_list", %{"initiative_id" => id, "chunk_type" => type}) do
    valid = Codrift.Memory.valid_types()

    if type in valid do
      {:ok, Codrift.Memory.list(id, type)}
    else
      {:error, "invalid chunk_type '#{type}'. Must be one of: #{Enum.join(valid, ", ")}"}
    end
  end

  def call("start_oauth_flow", %{"service" => service}) do
    case Codrift.OAuth.start_flow(service) do
      {:ok, %{flow: :pkce_browser, auth_url: url}} ->
        {:ok,
         %{
           flow: "pkce_browser",
           service: service,
           auth_url: url,
           message:
             "Open this URL in a browser to authorize #{service}. " <>
               "The Codrift server will save the token automatically."
         }}

      {:ok, %{flow: :guided_token, instructions: instructions}} ->
        {:ok,
         %{
           flow: "guided_token",
           service: service,
           instructions: instructions,
           message:
             "Show these instructions to the user, ask them to paste the token, " <>
               "then call save_guided_token once you have it."
         }}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  def call("save_guided_token", %{"service" => service, "token" => token}) do
    case Codrift.OAuth.save_guided_token(service, token) do
      :ok -> {:ok, %{connected: true, service: service}}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def call("get_oauth_status", _args) do
    all = OAuthConfig.supported_services()

    status =
      Map.new(all, fn service ->
        {service, %{connected: Codrift.OAuth.connected?(service), oauth_supported: true}}
      end)

    {:ok, %{services: status}}
  end

  def call("list_integration_items", %{"service" => service} = args) do
    opts = if filter = args["filter"], do: [filter: filter], else: []

    with {:ok, adapter} <- Codrift.Integration.adapter_for(service),
         {:ok, items} <- adapter.list_items(opts) do
      {:ok, Enum.map(items, &integration_item_to_map/1)}
    end
  end

  def call("import_from_integration", %{"service" => service, "item_id" => item_id} = args) do
    opts = if dir = args["dir"], do: [dir: dir], else: []

    case Codrift.Integration.import_item(service, item_id, opts) do
      {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def call("sync_initiative_context", %{"initiative_id" => id}) do
    case Codrift.Integration.sync_initiative(id) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def call("start_conductor", %{"initiative_id" => id} = args) do
    case Store.get(id) do
      {:ok, initiative} ->
        adapter = args |> Map.get("adapter", "claude") |> adapter_module()

        case Codrift.ConductorSupervisor.start_conductor(initiative, adapter) do
          {:ok, pid} ->
            {:ok, %{"started" => true, "initiative_id" => id, "pid" => inspect(pid)}}

          {:error, {:already_started, _}} ->
            {:ok, %{"started" => false, "reason" => "already running"}}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      {:error, :not_found} ->
        {:error, "initiative not found: #{id}"}
    end
  end

  def call("start_orchestration", %{"initiative_id" => id, "task" => task} = args) do
    case Store.get(id) do
      {:ok, initiative} ->
        adapter = args |> Map.get("adapter", "claude") |> adapter_module()
        extra = if dir = args["context_dir"], do: [context_dir: dir], else: []

        case Codrift.ConductorSupervisor.start_orchestration(initiative, adapter, task, extra) do
          {:ok, pid} ->
            {:ok, %{"started" => true, "initiative_id" => id, "pid" => inspect(pid)}}

          {:error, {:already_started, _}} ->
            {:ok, %{"started" => false, "reason" => "already running"}}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      {:error, :not_found} ->
        {:error, "initiative not found: #{id}"}
    end
  end

  def call("get_conductor_status", %{"initiative_id" => id}) do
    case Codrift.ConductorSupervisor.find_conductor(id) do
      {:ok, pid} ->
        statuses =
          pid
          |> Codrift.Conductor.agent_status()
          |> Map.new(fn {agent_id, info} ->
            {agent_id,
             %{
               dir: info.dir,
               status: Atom.to_string(info.status),
               role: Atom.to_string(info.role)
             }}
          end)

        {:ok, %{"initiative_id" => id, "agents" => statuses}}

      {:error, :not_found} ->
        {:error, "no conductor running for initiative: #{id}"}
    end
  end

  def call("get_conductor_results", %{"initiative_id" => id}) do
    case Codrift.ConductorSupervisor.find_conductor(id) do
      {:ok, pid} ->
        results =
          pid
          |> Codrift.Conductor.results()
          |> Map.new(fn {agent_id, chunks} -> {agent_id, Enum.join(chunks)} end)

        {:ok, %{"initiative_id" => id, "results" => results}}

      {:error, :not_found} ->
        {:error, "no conductor running for initiative: #{id}"}
    end
  end

  def call("read_orchestration_md", %{"initiative_id" => id}) do
    case Store.read_orchestration_md(id) do
      {:ok, content} -> {:ok, %{"initiative_id" => id, "content" => content}}
      {:error, reason} -> {:error, "could not read orchestration.md: #{inspect(reason)}"}
    end
  end

  def call("update_orchestration_md", %{"initiative_id" => id, "content" => content}) do
    case Store.update_orchestration_md(id, content) do
      :ok -> {:ok, %{"updated" => true, "initiative_id" => id}}
      {:error, reason} -> {:error, "could not write orchestration.md: #{inspect(reason)}"}
    end
  end

  def call("get_keybindings", _args) do
    {:ok, Codrift.Config.Keybindings.load()}
  end

  def call("list_context_files", %{"initiative_id" => id}) do
    case Store.get(id) do
      {:ok, _initiative} ->
        dir = Store.context_path(id)

        files =
          case File.ls(dir) do
            {:ok, names} ->
              names
              |> Enum.reject(
                &(String.starts_with?(&1, ".") or &1 == "CLAUDE.md" or
                    String.ends_with?(&1, ".db"))
              )
              |> Enum.filter(&File.regular?(Path.join(dir, &1)))
              |> Enum.sort()

            {:error, _} ->
              []
          end

        {:ok, %{"files" => files}}

      {:error, :not_found} ->
        {:error, "initiative not found: #{id}"}
    end
  end

  def call("read_context_file", %{"initiative_id" => id, "name" => name}) do
    with {:ok, _initiative} <- Store.get(id),
         :ok <- validate_basename(name),
         path = Path.join(Store.context_path(id), name),
         true <- File.regular?(path),
         {:ok, content} <- File.read(path) do
      {:ok, %{"name" => name, "content" => content}}
    else
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
      {:error, :invalid_name} -> {:error, "invalid file name"}
      false -> {:error, "context file not found: #{name}"}
      {:error, reason} -> {:error, "could not read context file: #{inspect(reason)}"}
    end
  end

  def call("list_tree", %{"initiative_id" => id}) do
    case Store.get(id) do
      {:ok, initiative} ->
        dirs =
          Enum.map(initiative.dirs, fn entry ->
            base = DirEntry.effective_path(entry)
            %{"dir" => base, "files" => Codrift.Files.list_relative(base)}
          end)

        {:ok, %{"dirs" => dirs}}

      {:error, :not_found} ->
        {:error, "initiative not found: #{id}"}
    end
  end

  def call("read_file", %{"initiative_id" => id, "path" => path}) do
    with {:ok, initiative} <- Store.get(id),
         allowed = Enum.map(initiative.dirs, &DirEntry.effective_path/1),
         {:ok, content} <- Codrift.Files.read_within(allowed, path) do
      {:ok, %{"path" => path, "content" => content}}
    else
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
      {:error, :forbidden} -> {:error, "path is outside the initiative's directories"}
      {:error, :too_large} -> {:error, "file is too large to preview"}
      {:error, :not_a_file} -> {:error, "not a regular file"}
      {:error, reason} -> {:error, "could not read file: #{inspect(reason)}"}
    end
  end

  def call("write_file", %{"initiative_id" => id, "path" => path, "content" => content})
      when is_binary(content) do
    with {:ok, initiative} <- Store.get(id),
         allowed = Enum.map(initiative.dirs, &DirEntry.effective_path/1),
         :ok <- Codrift.Files.write_within(allowed, path, content) do
      {:ok, %{"path" => path, "bytes" => byte_size(content)}}
    else
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
      {:error, :forbidden} -> {:error, "path is outside the initiative's directories"}
      {:error, :not_a_file} -> {:error, "target is a directory"}
      {:error, reason} -> {:error, "could not write file: #{inspect(reason)}"}
    end
  end

  def call(name, _args), do: {:error, "unknown tool: #{name}"}

  defp integration_item_to_map(%Codrift.Integration.Item{} = item) do
    %{
      id: item.id,
      title: item.title,
      url: item.url,
      status: item.status,
      assignee: item.assignee,
      labels: item.labels || []
    }
  end

  defp dir_diffs(dir) do
    case Codrift.Diff.generate(dir) do
      {:ok, files} -> Enum.map(files, &Codrift.Diff.to_map/1)
      {:error, _} -> []
    end
  end

  # Guards a context-file name to a plain basename — no directory separators or
  # traversal — so reads stay inside the initiative's context folder.
  # Initiative map enriched with its context folder path, so the UI can offer
  # the context folder as a scratch workspace and label it nicely.
  defp initiative_map(initiative) do
    initiative
    |> Codrift.Initiative.to_map()
    |> Map.put("context_path", Store.context_path(initiative.id))
  end

  defp validate_basename(name) when is_binary(name) do
    if name not in ["", ".", ".."] and not String.contains?(name, "/") and
         name == Path.basename(name),
       do: :ok,
       else: {:error, :invalid_name}
  end

  defp validate_basename(_), do: {:error, :invalid_name}

  defp adapter_module("terminal"), do: Codrift.Agent.Adapters.Terminal

  defp adapter_module(name) do
    Codrift.Agent.module_from_name(name) || raise("unknown adapter: #{name}")
  end

  # Clamps memory_recent limit to 1..100. Accepts integers only; any other
  # type (float, nil) falls back to the default of 20.
  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, 100)
  defp clamp_limit(_), do: 20
end

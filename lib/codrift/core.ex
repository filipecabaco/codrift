defmodule Codrift.Core do
  @moduledoc """
  Shared operation layer behind every Codrift surface.

  The MCP server (`Codrift.MCP.Handler`), the HTTP/JSON API (`POST /api/rpc`),
  and the web UI all route through `call/2`. Each operation takes a name and a
  string-keyed argument map and returns `{:ok, result}` or `{:error, message}`.

  This is the single source of truth for what the product can *do*; the
  transports above it only translate envelopes (JSON-RPC, REST, WebSocket).
  """

  alias Codrift.Config.Keybindings
  alias Codrift.Config.Settings
  alias Codrift.Initiative.{DirEntry, Pinned, Store}
  alias Codrift.MCP.Handler
  alias Codrift.OAuth.Config, as: OAuthConfig
  alias Codrift.Updater.Runner
  alias Codrift.Web.EventRelay
  alias Codrift.Worktree.Inventory

  # The MCP door. Everything arriving through it is an *agent* acting, not the
  # person at the keyboard, so agents started that way are marked `:directed`
  # and the sidebar draws them apart from the ones the user started.
  #
  # Carried in the process dictionary rather than as a parameter because `call/2`
  # has some eighty clauses and threading a third argument through every one of
  # them to serve two is the worse trade.
  @source_key :codrift_call_source

  @doc """
  `call/2` on behalf of a specific caller.

  Pass `source: :mcp` from the MCP handler. Anything else, including omitting it,
  is treated as the user acting directly.
  """
  def call(name, args, opts) do
    Process.put(@source_key, Keyword.get(opts, :source, :user))
    call(name, args)
  after
    Process.delete(@source_key)
  end

  # An agent the user started is theirs; one started through the MCP door was
  # started by another agent. See `Codrift.AgentProcess` for the roles.
  #
  # Only `start_agent` asks. `open_terminal` deliberately does not: it prefills a
  # command *without* submitting it and returns `awaiting_user: true`, so even
  # over MCP it is a terminal handed to the person, not an agent being driven.
  defp agent_role do
    if Process.get(@source_key) == :mcp, do: :directed, else: :user
  end

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
         Enum.flat_map(initiative.dirs, fn entry ->
           entry
           |> DirEntry.effective_path()
           |> dir_diffs()
           |> Enum.map(&Map.put(&1, "dir", entry.path))
         end)}

      {:error, :not_found} ->
        {:error, "initiative not found: #{initiative_id}"}
    end
  end

  def call("list_agents", _args) do
    agents = Enum.map(Codrift.AgentSupervisor.list_agents(), &EventRelay.describe/1)

    {:ok, agents}
  end

  def call("get_initiative_agents", %{"initiative_id" => initiative_id}) do
    agents =
      initiative_id
      |> Codrift.AgentSupervisor.list_agents_for_initiative()
      |> Enum.map(&EventRelay.describe/1)

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

  def call("start_agent", %{"initiative_id" => init_id} = params) do
    {adapter, profile} = launch_choice(init_id, params)

    with {:ok, launch} <- resolve_launch(adapter, profile),
         {:ok, dir} <- resolve_agent_dir(init_id, Map.get(params, "dir")),
         {:ok, pid} <-
           Codrift.AgentSupervisor.start_agent(init_id, dir, launch.module,
             profile: launch.profile,
             profile_env: launch.env,
             command: launch.command,
             extra_args: launch.args,
             role: agent_role()
           ) do
      {:ok, EventRelay.describe(pid)}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("open_terminal", %{"initiative_id" => init_id} = params) do
    with {:ok, dir} <- resolve_agent_dir(init_id, Map.get(params, "dir")),
         {:ok, pid} <-
           Codrift.AgentSupervisor.start_agent(init_id, dir, Codrift.Agent.Adapters.Terminal) do
      status = EventRelay.describe(pid)
      command = prefill(pid, Map.get(params, "command"))
      EventRelay.broadcast({:pane_request, init_id, status.id, Map.get(params, "reason")})

      {:ok, Map.merge(status, %{prefilled: command, awaiting_user: true})}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # Pin a file into the initiative and put it in front of the user. Two halves of
  # one thing on purpose: an agent that has found the file that matters should
  # not have to choose between showing it now and leaving it findable later.
  def call("open_file", %{"initiative_id" => id, "path" => path} = params) do
    with {:ok, initiative} <- Store.get(id),
         allowed = Enum.map(initiative.dirs, &DirEntry.effective_path/1),
         {:ok, pinned} <-
           Pinned.pin(
             Store.context_path(id),
             allowed,
             path,
             Map.get(params, "name")
           ) do
      EventRelay.broadcast({:file_request, id, pinned["name"], Map.get(params, "reason")})
      {:ok, pinned}
    else
      {:error, :not_found} ->
        {:error, "initiative not found: #{id}"}

      {:error, :forbidden} ->
        {:error,
         "#{path} is not inside any of this initiative's directories — " <>
           "add the directory first with add_dir"}

      {:error, :not_a_file} ->
        {:error, "not a regular file: #{path}"}

      {:error, :reserved} ->
        {:error, "the initiative already has a different context file by that name"}

      {:error, reason} ->
        {:error, "could not pin #{path}: #{inspect(reason)}"}
    end
  end

  def call("focus_agent", %{"agent_id" => agent_id} = params) do
    case Codrift.AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} ->
        %{initiative_id: init_id} = Codrift.AgentProcess.status(pid)
        EventRelay.broadcast({:pane_request, init_id, agent_id, Map.get(params, "reason")})
        {:ok, %{"focused" => agent_id}}

      {:error, :not_found} ->
        {:error, "agent not found: #{agent_id}"}
    end
  end

  def call("list_agent_profiles", _args) do
    profiles =
      Settings.profiles()
      |> Enum.map(fn {name, p} -> %{name: name, adapter: Map.get(p, "adapter")} end)
      |> Enum.sort_by(& &1.name)

    {:ok, profiles}
  end

  # The launch-facing list above stays deliberately thin (name + adapter): it is
  # an MCP tool, so its result lands in agent context. This one is the config
  # view's, and carries the env each profile sets.
  def call("get_agent_profiles", _args) do
    profiles =
      Settings.profiles()
      |> Enum.map(fn {name, p} ->
        %{
          name: name,
          adapter: Map.get(p, "adapter"),
          command: Map.get(p, "command"),
          args: p |> Map.get("args", []) |> Enum.map(&to_string/1),
          env: p |> Map.get("env", %{}) |> stringify_env()
        }
      end)
      |> Enum.sort_by(& &1.name)

    {:ok, %{"profiles" => profiles}}
  end

  # Upsert. `previous_name` (optional) is the profile being renamed, dropped
  # only once the new one validates — a rejected rename leaves the original in
  # place rather than deleting a working profile.
  def call("save_agent_profile", %{"name" => name, "adapter" => adapter} = args) do
    with {:ok, name} <- validate_profile_name(name),
         {:ok, adapter} <- validate_profile_adapter(adapter),
         {:ok, command} <- validate_profile_command(Map.get(args, "command")),
         {:ok, extra_args} <- validate_profile_args(Map.get(args, "args", [])),
         {:ok, env} <- validate_profile_env(Map.get(args, "env", %{})) do
      case Map.get(args, "previous_name") do
        prev when is_binary(prev) and prev != "" and prev != name -> Settings.delete_profile(prev)
        _ -> :ok
      end

      Settings.put_profile(name, %{adapter: adapter, command: command, args: extra_args, env: env})

      {:ok,
       %{
         "name" => name,
         "adapter" => adapter,
         "command" => command,
         "args" => extra_args,
         "env" => env
       }}
    end
  end

  def call("delete_agent_profile", %{"name" => name}) when is_binary(name) do
    case Settings.delete_profile(name) do
      :ok -> {:ok, %{"deleted" => name}}
      {:error, :not_found} -> {:error, "unknown launch profile: #{name}"}
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

    with {:ok, agent} <- validate_agent_choice(Map.get(args, "agent")),
         {:ok, initiative} <- Store.create(name, dirs) do
      if agent do
        Settings.put_default_agent(agent)
        {:ok, updated} = Store.set_agent(initiative.id, agent)
        {:ok, Codrift.Initiative.to_map(updated)}
      else
        {:ok, Codrift.Initiative.to_map(initiative)}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # Opens a scratchpad: an initiative created without a name, a directory, or a
  # decision about what it is for.
  #
  # The point is a session you can start before you know whether the work is
  # worth filing — exploration, a one-off command, a question. It carries the
  # full machinery of an initiative (context folder, memory, agents) so that if
  # it turns out to matter, `promote_initiative` gives it a name and it *becomes*
  # the initiative, keeping everything it accumulated on the way.
  def call("create_scratchpad", args) do
    # A scratchpad opened while the cursor is on a directory belongs *there* —
    # exploring is what it is for, and an empty folder has nothing to explore.
    # With no directory it stays folderless and runs in its own context folder.
    dirs = args |> Map.get("dirs", []) |> Enum.map(&Path.expand/1)
    taken = Store.list() |> Enum.filter(& &1.scratch) |> Enum.map(& &1.name)
    label = dirs |> List.first() |> dir_label()
    name = Map.get(args, "name") || Codrift.Initiative.scratch_name(taken, label)

    with {:ok, agent} <- validate_agent_choice(Map.get(args, "agent")),
         {:ok, initiative} <- Store.create_scratch(name, dirs) do
      # Deliberately does NOT touch the global default agent the way
      # create_initiative does: a throwaway session must not redefine what every
      # future initiative launches.
      if agent do
        {:ok, updated} = Store.set_agent(initiative.id, agent)
        {:ok, initiative_map(updated)}
      else
        {:ok, initiative_map(initiative)}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # Ranks a scratchpad up into a real initiative under `name`. Nothing moves: the
  # same context folder, memory store and running agents carry over, so promoting
  # mid-session never interrupts anything.
  def call("promote_initiative", %{"initiative_id" => id, "name" => name})
      when is_binary(name) do
    case String.trim(name) do
      "" ->
        {:error, "name cannot be empty"}

      trimmed ->
        case Store.promote(id, trimmed) do
          {:ok, initiative} -> {:ok, initiative_map(initiative)}
          {:error, :not_found} -> {:error, "initiative not found: #{id}"}
        end
    end
  end

  def call("rename_initiative", %{"initiative_id" => id, "name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" ->
        {:error, "name cannot be empty"}

      trimmed ->
        case Store.rename(id, trimmed) do
          {:ok, initiative} -> {:ok, initiative_map(initiative)}
          {:error, :not_found} -> {:error, "initiative not found: #{id}"}
        end
    end
  end

  def call("set_initiative_agent", %{"initiative_id" => id} = args) do
    with {:ok, agent} <- validate_agent_choice(Map.get(args, "agent")) do
      case Store.set_agent(id, agent) do
        {:ok, initiative} -> {:ok, initiative_map(initiative)}
        {:error, :not_found} -> {:error, "initiative not found: #{id}"}
      end
    end
  end

  def call("get_default_agent", _args) do
    {:ok, %{"agent" => Settings.default_agent() || "claude"}}
  end

  def call("set_default_agent", %{"agent" => agent}) do
    with {:ok, choice} <- validate_agent_choice(agent) do
      Settings.put_default_agent(choice || "claude")
      {:ok, %{"agent" => choice || "claude"}}
    end
  end

  # Backs the "add directory" fuzzy picker: given a partially-typed path
  # (defaulting to the configured workspace folder, else `~`), returns the
  # directory being browsed plus its child directory names so the UI can
  # autocomplete. Read-only listing of the host filesystem — acceptable since
  # this is a local desktop app and `add_dir` already accepts arbitrary
  # absolute paths.
  def call("list_dirs", args) do
    # A blank path is "nothing typed yet", not "the current directory": letting
    # it through makes `Path.dirname/1` resolve to the server's cwd, which is
    # wherever the app happened to be launched from.
    path =
      case args |> Map.get("path", "") |> to_string() |> String.trim() do
        "" -> Settings.workspace_dir() || "~"
        typed -> typed
      end

    {:ok, Codrift.Files.list_subdirs(path)}
  end

  # Answers the question the "add directory" flow has to ask before it commits:
  # is this a repo the user could work on in an isolated worktree, or a plain
  # folder to add as-is? Read-only, like `list_dirs` next to it.
  def call("inspect_dir", %{"path" => path}) do
    {:ok, Codrift.Files.inspect_path(path)}
  end

  # Where the directory picker starts browsing. Most people keep every repo
  # under one folder, and starting at `~` meant retyping the same two segments
  # on every add.
  def call("get_workspace_dir", _args) do
    {:ok, %{"path" => Settings.workspace_dir()}}
  end

  # An empty path clears the preference rather than storing "", so the picker
  # goes back to `~` instead of browsing the process's working directory.
  def call("set_workspace_dir", %{"path" => path}) when is_binary(path) do
    case String.trim(path) do
      "" ->
        Settings.clear_workspace_dir()
        {:ok, %{"path" => nil}}

      trimmed ->
        # Validated, not expanded: a `~`-relative value stays portable, and a
        # typo silently accepted here would only surface as an empty picker.
        if File.dir?(Codrift.Files.expand_user(trimmed)) do
          Settings.put_workspace_dir(trimmed)
          {:ok, %{"path" => trimmed}}
        else
          {:error, "not a directory: #{trimmed}"}
        end
    end
  end

  def call("add_dir", %{"initiative_id" => id, "dir" => dir} = args) do
    expanded = Path.expand(dir)
    opts = if truthy?(Map.get(args, "worktree")), do: [worktree_enabled: true], else: []

    case Store.add_dir(id, expanded, opts) do
      {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
    end
  end

  def call("remove_dir", %{"initiative_id" => id, "dir" => dir}) do
    expanded = Path.expand(dir)

    case Store.remove_dir(id, expanded) do
      {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
    end
  end

  # ── Git ─────────────────────────────────────────────────────────────────────
  #
  # Every one of these routes its `dir` through `DirEntry.resolve/2` before
  # touching git. That is the whole point: agent work lands in the worktree, and
  # the UI names the source path, so committing or pushing the source would push
  # a branch with none of the work on it.

  def call("git_fetch", %{"initiative_id" => id} = args) do
    with_git_dir(id, args, &Codrift.Git.fetch/1)
  end

  def call("git_rebase", %{"initiative_id" => id} = args) do
    with_git_dir(id, args, &Codrift.Git.rebase/1)
  end

  def call("git_commit", %{"initiative_id" => id, "message" => message} = args)
      when is_binary(message) do
    with_git_dir(id, args, &Codrift.Git.commit(&1, message))
  end

  def call("git_push", %{"initiative_id" => id} = args) do
    with_git_dir(id, args, &Codrift.Git.push/1)
  end

  def call("git_info", %{"initiative_id" => id} = args) do
    with_git_dir(id, args, fn dir ->
      case Codrift.Git.info(dir) do
        nil -> {:error, "#{dir} is not a git repository"}
        info -> {:ok, info}
      end
    end)
  end

  # The sidebar's directory preview: the repo's README if it has one, otherwise
  # a shallow tree. Scoped to directories the initiative actually holds, and
  # read through the entry's effective path so a worktree previews the worktree.
  def call("dir_preview", %{"initiative_id" => id, "path" => path}) do
    with {:ok, initiative} <- Store.get(id),
         %DirEntry{} = entry <- Enum.find(initiative.dirs, &(&1.path == path)) do
      {:ok, Codrift.Files.preview(DirEntry.effective_path(entry))}
    else
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
      nil -> {:error, "directory is not part of this initiative: #{path}"}
    end
  end

  def call("delete_initiative", %{"initiative_id" => id}) do
    case Store.get(id) do
      {:ok, _initiative} ->
        # Processes must go before files: a live conductor or sub-agent keeps
        # writing into the context dir (transcript logs), which makes the
        # recursive delete race with new files appearing under it.
        :ok = Codrift.ConductorSupervisor.stop_conductor(id)

        id
        |> Codrift.AgentSupervisor.list_agents_for_initiative()
        |> Enum.each(&Codrift.AgentSupervisor.stop_agent/1)

        case Store.delete(id) do
          :ok -> {:ok, %{"deleted" => id}}
          {:error, :not_found} -> {:error, "initiative not found: #{id}"}
        end

      {:error, :not_found} ->
        {:error, "initiative not found: #{id}"}
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

      {:ok,
       %{
         flow: :device_flow,
         user_code: user_code,
         verification_uri: verification_uri,
         device_code: device_code,
         expires_in: expires_in,
         interval: interval
       }} ->
        # No live process to notify in a stateless RPC — pass nil and let the
        # supervised poller save the token. The caller polls get_oauth_status.
        expires_at = System.os_time(:second) + expires_in

        Codrift.OAuth.poll_device_auth(
          nil,
          service,
          device_code,
          expires_at,
          interval,
          nil
        )

        {:ok,
         %{
           flow: "device_flow",
           service: service,
           user_code: user_code,
           verification_uri: verification_uri,
           message: "Visit #{verification_uri} and enter code #{user_code}"
         }}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  def call("open_url", %{"url" => url}) when is_binary(url) do
    if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      open_in_browser(url)
      {:ok, %{opened: true, url: url}}
    else
      {:error, "refusing to open non-http(s) URL"}
    end
  end

  def call("revoke_oauth_token", %{"service" => service}) do
    :ok = Codrift.OAuth.revoke_token(service)
    {:ok, %{connected: false, service: service}}
  end

  def call("get_oauth_status", _args) do
    all = OAuthConfig.supported_services()

    status =
      Map.new(all, fn service ->
        flow = with {:ok, config} <- OAuthConfig.get(service), do: config.flow

        {service,
         service
         |> Codrift.OAuth.status()
         |> Map.merge(%{oauth_supported: true, flow: to_string(flow)})}
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

  def call("branch_initiative", %{"initiative_id" => id}) do
    case Store.branch_all(id) do
      {:ok, result} -> {:ok, result}
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  # ── Worktrees ───────────────────────────────────────────────────────────────
  #
  # Worktrees have always lived at ~/.codrift/initiatives/<id>/worktrees/<slug>,
  # but nothing could enumerate them, so one left behind by a deleted initiative
  # stayed on disk holding a checkout and a branch that nobody could see. These
  # three operations are the whole loop — see what exists, clean up what nothing
  # claims, and turn one on or off for a directory.

  def call("list_worktrees", args) do
    entries = Inventory.scan(Store.list())

    filtered =
      case Map.get(args, "initiative_id") do
        nil -> entries
        id -> Enum.filter(entries, &(&1.initiative_id == id))
      end

    {:ok, Enum.map(filtered, &Inventory.to_map/1)}
  end

  def call("prune_worktrees", args) do
    # Defaults to a dry run: removing a worktree can destroy uncommitted work in
    # it, so a caller has to ask twice. Committed work survives either way — a
    # removed worktree keeps its branch.
    force? = Map.get(args, "force", false) == true
    {:ok, Inventory.prune_to_map(Inventory.prune(Store.list(), force: force?))}
  end

  def call("set_dir_worktree", %{"initiative_id" => id, "dir" => dir} = args) do
    enabled? = Map.get(args, "enabled", true) == true

    with {:ok, initiative} <- Store.get(id),
         {:ok, entry} <- find_dir(initiative, dir),
         {:ok, updated} <- Store.set_dir_worktree(id, entry.path, enabled?) do
      {:ok, initiative_map(updated)}
    else
      {:error, :not_found} ->
        {:error, "initiative not found: #{id}"}

      {:error, :no_such_dir} ->
        {:error, "#{dir} is not a directory of initiative #{id}"}

      {:error, {:worktree_failed, reason}} ->
        {:error, "could not create the worktree for #{dir}: #{reason}"}
    end
  end

  def call("toggle_dir_branch", %{"initiative_id" => id, "dir" => dir}) do
    case Store.toggle_dir_branch(id, dir) do
      {:ok, initiative} -> {:ok, initiative_map(initiative)}
      {:error, :not_found} -> {:error, "initiative or directory not found"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def call("list_assigned_items", args) do
    opts = if filter = args["filter"], do: [filter: filter], else: []
    %{items: items, errors: errors} = Codrift.Integration.list_assigned(opts)

    errors = Enum.map(errors, &Map.update!(&1, :kind, fn kind -> to_string(kind) end))

    {:ok, %{items: Enum.map(items, &assigned_item_to_map/1), errors: errors}}
  end

  def call("import_from_integration", %{"service" => service, "item_id" => item_id} = args) do
    opts = if dir = args["dir"], do: [dir: dir], else: []

    case Codrift.Integration.import_item(service, item_id, opts) do
      {:ok, outcome, initiative} ->
        {:ok, Map.put(Codrift.Initiative.to_map(initiative), "existing", outcome == :existing)}

      {:error, reason} ->
        {:error, to_string(reason)}
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

  def call("stop_orchestration", %{"initiative_id" => id}) do
    # Liveness, not just a registry hit: unregistration waits on the DOWN
    # message, so a lookup can still resolve a conductor that has already died.
    running? =
      case Codrift.ConductorSupervisor.find_conductor(id) do
        {:ok, pid} -> Process.alive?(pid)
        {:error, :not_found} -> false
      end

    :ok = Codrift.ConductorSupervisor.stop_conductor(id)
    {:ok, %{"initiative_id" => id, "stopped" => running?}}
  end

  def call("get_conductor_status", %{"initiative_id" => id}) do
    with_conductor(id, fn pid ->
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

      %{"initiative_id" => id, "agents" => statuses}
    end)
  end

  def call("get_conductor_results", %{"initiative_id" => id}) do
    with_conductor(id, fn pid ->
      results =
        pid
        |> Codrift.Conductor.results()
        |> Map.new(fn {agent_id, chunks} -> {agent_id, Enum.join(chunks)} end)

      %{"initiative_id" => id, "results" => results}
    end)
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
    {:ok, Keybindings.load()}
  end

  # ── Theming ────────────────────────────────────────────────────────────────
  # The UI speaks VS Code's theme format, so anything written for VS Code can be
  # dropped into ~/.codrift/themes and picked here.

  def call("get_theme", _args) do
    {:ok, %{"name" => Settings.theme()}}
  end

  def call("set_theme", %{"name" => name}) when is_binary(name) do
    Settings.put_theme(name)
    {:ok, %{"name" => name}}
  end

  def call("list_themes", _args) do
    {:ok, %{"themes" => Codrift.Themes.list()}}
  end

  def call("get_font", _args) do
    {:ok, Settings.font()}
  end

  def call("set_font", %{"family" => family, "size" => size})
      when is_binary(family) and is_integer(size) do
    # Clamped here as well as in the UI: settings.json is hand-editable, and a
    # 2px or 400px interface is not a state the app should be able to reach.
    size = size |> max(10) |> min(20)
    Settings.put_font(family, size)
    {:ok, %{"family" => family, "size" => size}}
  end

  def call("get_sidebar_sort", _args) do
    {:ok, %{"sort" => Settings.sidebar_sort()}}
  end

  def call("set_sidebar_sort", %{"sort" => sort}) when is_binary(sort) do
    # Validated here as well as in the UI: settings.json is hand-editable, and an
    # unknown ordering would leave the sidebar silently falling back while the
    # control claimed otherwise.
    if sort in Settings.sidebar_sorts() do
      Settings.put_sidebar_sort(sort)
      {:ok, %{"sort" => sort}}
    else
      {:error,
       "invalid sort: #{sort}. Must be one of: #{Enum.join(Settings.sidebar_sorts(), ", ")}"}
    end
  end

  def call("read_theme", %{"name" => name}) when is_binary(name) do
    case Codrift.Themes.read(name) do
      {:ok, theme} -> {:ok, theme}
      {:error, :not_found} -> {:error, "theme not found: #{name}"}
      {:error, :invalid} -> {:error, "not a valid VS Code theme: #{name}"}
    end
  end

  # Relative paths, not just basenames: an initiative folder is a working
  # workspace — people keep `scripts/deploy.sh` and `docs/runbook.md` in it —
  # and the sidebar renders whatever this returns as a tree.
  def call("list_context_files", %{"initiative_id" => id}) do
    case Store.get(id) do
      {:ok, _initiative} ->
        dir = Store.context_path(id)
        {:ok, %{"files" => context_files(dir)}}

      {:error, :not_found} ->
        {:error, "initiative not found: #{id}"}
    end
  end

  def call("read_context_file", %{"initiative_id" => id, "name" => name}) do
    # The initiative's directories are allowed roots here, not just the context
    # folder, because a pinned file of interest *is* a symlink out of it (see
    # `Codrift.Initiative.Pinned`). `read_within/2` resolves symlinks before
    # checking containment, so without them every pin read back as `:forbidden`.
    # The rule does not widen: `Pinned.pin/4` only ever links to a file those
    # same roots already contain.
    with {:ok, initiative} <- Store.get(id),
         :ok <- validate_context_path(name),
         dir = Store.context_path(id),
         allowed = [dir | Enum.map(initiative.dirs, &DirEntry.effective_path/1)],
         {:ok, content} <- Codrift.Files.read_within(allowed, Path.join(dir, name)) do
      {:ok, %{"name" => name, "content" => content}}
    else
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
      {:error, :invalid_name} -> {:error, "invalid file name"}
      {:error, :forbidden} -> {:error, "context file not found: #{name}"}
      {:error, :not_a_file} -> {:error, "context file not found: #{name}"}
      {:error, :enoent} -> {:error, "context file not found: #{name}"}
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

  # ── Updates ────────────────────────────────────────────────────────────────

  # What the UI needs to decide between "say nothing", "offer an update" and
  # "explain why it cannot install one". Never fails: a version probe that could
  # not reach GitHub is a quiet non-event, not an error the user has to dismiss,
  # so the reason travels in the payload and `available` stays false.
  def call("update_status", _args) do
    manager = Codrift.Updater.app_manager(Codrift.Updater.app_path())

    base = %{
      "current" => Codrift.Updater.current_version(),
      "manager" => Atom.to_string(manager),
      "cli_manager" => Atom.to_string(Codrift.Updater.cli_manager()),
      "brew_command" => Codrift.Updater.brew_upgrade_command(),
      "latest" => nil,
      "available" => false,
      "error" => nil
    }

    case Codrift.Updater.check() do
      {:update_available, _current, latest} ->
        {:ok, %{base | "latest" => latest, "available" => manager != :unknown}}

      {:up_to_date, version} ->
        {:ok, %{base | "latest" => version}}

      {:error, reason} ->
        {:ok, %{base | "error" => reason}}
    end
  end

  # Starts the update the user just accepted. The release is re-read here rather
  # than passed in from the browser: the asset list decides what gets downloaded
  # and executed, and that is not a decision to take from a request body.
  def call("start_update", _args) do
    with {:ok, %{version: version, assets: assets}} <- Codrift.Updater.fetch_latest_release(),
         {:ok, _stage} <- Runner.start(version, assets) do
      {:ok, Runner.status()}
    else
      {:error, :busy} -> {:error, "an update is already running"}
      {:error, reason} -> {:error, reason}
    end
  end

  def call("update_progress", _args), do: {:ok, Runner.status()}

  def call(name, args) do
    if name in Handler.tool_names() do
      {:error, "wrong arguments for #{name}: got #{inspect(Map.keys(args))}"}
    else
      {:error, "unknown tool: #{name}"}
    end
  end

  defp assigned_item_to_map(%{service: service, item: item} = assigned) do
    item
    |> integration_item_to_map()
    |> Map.merge(%{
      service: service,
      relation: assigned.relation,
      initiative_id: assigned.initiative_id,
      imported: not is_nil(assigned.initiative_id)
    })
  end

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

  # A successful lookup is not proof the process is alive: unregistration waits
  # on the DOWN message.
  defp with_conductor(id, fun) do
    case Codrift.ConductorSupervisor.find_conductor(id) do
      {:ok, pid} ->
        try do
          {:ok, fun.(pid)}
        catch
          :exit, _ -> {:error, "no conductor running for initiative: #{id}"}
        end

      {:error, :not_found} ->
        {:error, "no conductor running for initiative: #{id}"}
    end
  end

  defp dir_diffs(dir) do
    case Codrift.Diff.generate(dir) do
      {:ok, files} -> Enum.map(files, &Codrift.Diff.to_map/1)
      {:error, _} -> []
    end
  end

  # The directory a scratchpad was opened against, as its name reads it.
  defp dir_label(nil), do: nil
  defp dir_label(path), do: Path.basename(path)

  # Stored paths are whatever the caller passed to add_dir, so match the literal
  # string first and fall back to comparing expanded forms — an agent passing
  # `~/code/app` should still find the directory added as an absolute path.
  defp find_dir(initiative, dir) do
    expanded = Path.expand(dir)

    case Enum.find(initiative.dirs, &(&1.path == dir || Path.expand(&1.path) == expanded)) do
      nil -> {:error, :no_such_dir}
      entry -> {:ok, entry}
    end
  end

  @doc """
  Initiative map enriched with its context folder path, so the UI can offer
  the context folder as a scratch workspace and label it nicely.

  This is the initiative's shape at the API boundary, shared by every surface
  that emits one: `list_initiatives` here and the lifecycle frames in
  `Codrift.Web.EventRelay`. A frame the client patches state from has to match
  what it originally loaded, or the patched row loses `context_path` and the
  per-dir `git` flag.
  """
  def initiative_map(initiative) do
    initiative
    |> Codrift.Initiative.to_map()
    |> Map.put("context_path", Store.context_path(initiative.id))
    |> Map.update!("dirs", fn dirs -> Enum.map(dirs, &tag_git/1) end)
  end

  # MCP clients send booleans as booleans, but a hand-written CLI call or a
  # loosely-typed client may send the string. Both mean the same thing here.
  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  # Derived at the API boundary, never persisted: whether a directory is under
  # version control decides how the UI draws it (a repo you can diff vs a plain
  # folder), and that can change on disk between two calls.
  defp tag_git(%{"path" => path} = dir), do: Map.put(dir, "git", Codrift.Files.in_git_repo?(path))

  # Everything the user keeps in the initiative folder, as paths relative to it:
  # `initiative.md`, but also `scripts/deploy.sh` and `docs/runbook.md`. Skips
  # Codrift's own bookkeeping — dot-prefixed entries (agent logs), the generated
  # CLAUDE.md, the memory database, and `worktrees/`, which holds git checkouts
  # the sidebar already lists as directories in their own right. Without that
  # last one, enabling a worktree added a phantom `worktrees/<slug>/` row that
  # errored on click, because it names a directory and not a file.
  defp context_files(dir) do
    dir
    |> Codrift.Files.list_relative()
    |> Enum.reject(fn rel ->
      rel == "CLAUDE.md" or String.ends_with?(rel, ".db") or
        hd(Path.split(rel)) == "worktrees" or
        Enum.any?(Path.split(rel), &String.starts_with?(&1, "."))
    end)
    |> Enum.sort()
  end

  # Guards a context-file path: relative, no traversal. `Files.read_within/2`
  # then re-checks containment against the resolved folder, so a symlink inside
  # it cannot reach out either.
  defp validate_context_path(name) when is_binary(name) do
    segments = Path.split(name)

    if name not in ["", ".", ".."] and Path.type(name) == :relative and
         ".." not in segments and "." not in segments,
       do: :ok,
       else: {:error, :invalid_name}
  end

  defp validate_context_path(_), do: {:error, :invalid_name}

  defp adapter_module("terminal"), do: Codrift.Agent.Adapters.Terminal

  defp adapter_module(name) do
    Codrift.Agent.module_from_name(name) || raise("unknown adapter: #{name}")
  end

  defp resolve_launch(adapter, profile) when profile in [nil, ""],
    do: {:ok, %{module: adapter_module(adapter), env: [], profile: nil, command: nil, args: []}}

  defp resolve_launch(adapter, profile_name) do
    with {:ok, profile} <- fetch_profile(profile_name),
         {:ok, command} <- resolve_profile_command(profile) do
      base = Map.get(profile, "adapter", adapter)

      {:ok,
       %{
         module: adapter_module(base),
         env: expand_env(Map.get(profile, "env", %{})),
         profile: profile_name,
         command: command,
         args: profile |> Map.get("args", []) |> Enum.map(&to_string/1)
       }}
    end
  end

  defp launch_choice(init_id, params) do
    case {Map.get(params, "adapter"), Map.get(params, "profile")} do
      {nil, nil} -> split_choice(default_choice(init_id))
      {adapter, profile} -> {adapter || "claude", profile}
    end
  end

  defp default_choice(init_id) do
    initiative_agent =
      case Store.get(init_id) do
        {:ok, initiative} -> initiative.agent
        {:error, :not_found} -> nil
      end

    initiative_agent || Settings.default_agent() || "claude"
  end

  defp split_choice(choice) do
    if known_adapter?(choice), do: {choice, nil}, else: {"claude", choice}
  end

  defp fetch_profile(name) do
    case Settings.profile(name) do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> {:error, "unknown launch profile: #{name}"}
    end
  end

  defp resolve_profile_command(profile) do
    case Map.get(profile, "command") do
      cmd when is_binary(cmd) and cmd != "" -> Codrift.Agent.resolve_command(cmd)
      _ -> {:ok, nil}
    end
  end

  # A profile name shares the Launch dropdown with the base adapters and is
  # matched against them by name, so one called "claude" would silently shadow
  # the real adapter. Keep it identifier-shaped: it also shows as a badge and
  # travels as a `--profile` argument.
  defp validate_profile_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, "profile name can't be empty"}

      not Regex.match?(~r/^[\w.-]+$/u, trimmed) ->
        {:error, "profile name may only contain letters, digits, '-', '_' and '.'"}

      known_adapter?(trimmed) ->
        {:error, "'#{trimmed}' is a base adapter — pick a different profile name"}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_profile_name(_), do: {:error, "profile name must be a string"}

  defp validate_profile_adapter(adapter) when is_binary(adapter) do
    if known_adapter?(adapter),
      do: {:ok, adapter},
      else: {:error, "unknown adapter: #{adapter}"}
  end

  defp validate_profile_adapter(_), do: {:error, "adapter must be a string"}

  defp validate_profile_command(command) when command in [nil, ""], do: {:ok, nil}

  defp validate_profile_command(command) when is_binary(command) do
    with {:ok, _resolved} <- Codrift.Agent.resolve_command(command),
         do: {:ok, String.trim(command)}
  end

  defp validate_profile_command(_), do: {:error, "command must be a string"}

  defp validate_profile_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1),
      do: {:ok, args |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))},
      else: {:error, "each argument must be a string"}
  end

  defp validate_profile_args(_), do: {:error, "args must be a list of strings"}

  defp known_adapter?(name), do: not is_nil(Codrift.Agent.module_from_name(name))

  defp validate_agent_choice(choice) when choice in [nil, ""], do: {:ok, nil}

  defp validate_agent_choice(choice) when is_binary(choice) do
    cond do
      known_adapter?(choice) -> {:ok, choice}
      Map.has_key?(Settings.profiles(), choice) -> {:ok, choice}
      true -> {:error, "unknown agent: #{choice}"}
    end
  end

  defp validate_agent_choice(_), do: {:error, "agent must be a string"}

  # Env is injected into a spawned process, so keys have to be real variable
  # names and values plain strings — a map or list here would blow up at spawn
  # time, far from the form that accepted it.
  defp validate_profile_env(env) when is_map(env) do
    Enum.reduce_while(env, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = key |> to_string() |> String.trim()

      cond do
        not Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) ->
          {:halt, {:error, "invalid environment variable name: #{inspect(key)}"}}

        not is_binary(value) ->
          {:halt, {:error, "value for #{key} must be a string"}}

        true ->
          {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp validate_profile_env(_), do: {:error, "env must be an object of NAME → value"}

  defp stringify_env(env) when is_map(env) do
    Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp stringify_env(_), do: %{}

  defp expand_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_string(k), expand_value(to_string(v))} end)
  end

  defp expand_env(_), do: []

  defp expand_value("~" <> _ = v), do: Path.expand(v)
  defp expand_value(v), do: v

  # A concrete directory runs the agent there. A blank/absent one means a
  # folderless ("scratch") initiative — fall back to its own context folder as
  # the working dir (same as `add_context_workspace`), registering it so tree,
  # diff and the editor operate there too. Agents no longer need a project
  # directory configured up front.
  defp resolve_agent_dir(init_id, dir) when is_binary(dir) and dir != "" do
    # Routed through the initiative's entries rather than expanded blindly: a
    # directory with a worktree has two paths, and every caller in the UI names
    # the source one. See `DirEntry.resolve/2`.
    case Store.get(init_id) do
      {:ok, initiative} -> {:ok, DirEntry.resolve(dir, initiative.dirs)}
      {:error, :not_found} -> {:ok, Path.expand(dir)}
    end
  end

  defp resolve_agent_dir(init_id, _blank) do
    with {:ok, _initiative} <- Store.add_dir(init_id, Store.context_path(init_id)) do
      {:ok, Store.context_path(init_id)}
    end
  end

  # Picks the directory a git action runs in and reports the result with the
  # directory attached, so the UI can say which repository it acted on when an
  # initiative holds several.
  defp with_git_dir(init_id, args, fun) do
    case git_dir(init_id, Map.get(args, "dir")) do
      {:ok, dir} ->
        case fun.(dir) do
          {:ok, result} -> {:ok, Map.put(result, "dir", dir)}
          {:error, message} -> {:error, message}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp git_dir(init_id, dir) do
    case Store.get(init_id) do
      {:error, :not_found} -> {:error, "initiative not found: #{init_id}"}
      {:ok, initiative} -> resolve_git_dir(initiative, dir)
    end
  end

  defp resolve_git_dir(initiative, dir) when is_binary(dir) and dir != "",
    do: {:ok, DirEntry.resolve(dir, initiative.dirs)}

  # No directory named: fall back to the initiative's only repository. Guessing
  # between several would act on the wrong one silently.
  defp resolve_git_dir(initiative, _dir) do
    initiative.dirs
    |> Enum.filter(&Codrift.Worktree.git_repo?(DirEntry.effective_path(&1)))
    |> case do
      [entry] -> {:ok, DirEntry.effective_path(entry)}
      [] -> {:error, "this initiative has no git repository"}
      _ -> {:error, "several repositories here — select one in the sidebar first"}
    end
  end

  # A shell that is still coming up flushes whatever is sitting in the tty queue
  # when its line editor (ZLE, readline) takes over. Typing into it the moment
  # `:exec.run` returns is therefore a coin flip, and losing the prefill is worse
  # than a beat of latency: the user is left staring at a bare prompt with no
  # idea what the agent meant them to run.
  @prefill_delay_ms 300

  # Types `command` at the prompt WITHOUT submitting it.
  #
  # `send_input/2` submits what it sends — that runs things, which is exactly
  # what this tool must not do. `send_raw/2` leaves the line sitting at the prompt for the
  # user to read and press Return on themselves. Newlines inside the command are
  # flattened to spaces for the same reason: an embedded `\n` would submit every
  # line before it, turning a draft into an execution.
  #
  # Returns the text actually typed, so the caller can report it back.
  defp prefill(_pid, blank) when blank in [nil, ""], do: nil

  defp prefill(pid, command) when is_binary(command) do
    typed = command |> String.replace(~r/[\r\n]+/, " ") |> String.trim()

    if typed == "" do
      nil
    else
      Task.Supervisor.start_child(Codrift.TaskSupervisor, fn ->
        Process.sleep(@prefill_delay_ms)
        Codrift.AgentProcess.send_raw(pid, typed)
      end)

      typed
    end
  end

  defp prefill(_pid, _other), do: nil

  # Clamps memory_recent limit to 1..100. Accepts integers only; any other
  # type (float, nil) falls back to the default of 20.
  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, 100)
  defp clamp_limit(_), do: 20

  # Opens a URL in the user's default browser. The web UI runs inside a Tauri
  # webview that can't itself launch the system browser, so it delegates here —
  # the backend runs on the same machine. Best-effort per OS; failures are
  # swallowed (the UI also shows the raw URL as a copy/paste fallback).
  defp open_in_browser(url) do
    {cmd, args} =
      case :os.type() do
        {:win32, _} -> {"cmd", ["/c", "start", "", url]}
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
      end

    Task.Supervisor.start_child(Codrift.TaskSupervisor, fn ->
      System.cmd(cmd, args, stderr_to_stdout: true)
    end)

    :ok
  rescue
    _ -> :ok
  end
end

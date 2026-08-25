defmodule Codrift.Web.E2ETest do
  @moduledoc """
  End-to-end coverage of the product's capability surface, driven through the
  real HTTP boundary (`POST /api/rpc` → `Codrift.Core` → the live, sandboxed
  backend: Initiative.Store, Memory/FTS5, Files, Diff, OAuth, agents).

  Unlike the unit tests, nothing here is injected or stubbed — these exercise
  the same global processes the desktop UI and MCP server talk to, so they act
  as the regression net that guards feature behaviour during code cleanup.

  `HOME` is redirected to a throwaway sandbox in `config/runtime.exs`, so these
  never touch the user's real `~/.codrift` / `~/.config/codrift`.

  Not `async` — every test shares the application's global Store and agent
  supervisor, so each test creates its own initiative and cleans up after itself.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Codrift.Branch
  alias Codrift.Initiative.Store
  alias Codrift.Test.GitRepo

  @opts Codrift.init([])

  # ── HTTP helpers ─────────────────────────────────────────────────────────────

  # Drives a Core operation through the real POST /api/rpc route and returns
  # {status, decoded_body}. This is the exact path the web UI uses.
  defp rpc(name, args) do
    conn =
      conn(:post, "/api/rpc", Jason.encode!(%{"name" => name, "args" => args}))
      |> put_req_header("content-type", "application/json")
      |> Codrift.call(@opts)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  # Unwraps a successful {200, %{"ok" => result}} envelope.
  defp ok!(name, args \\ %{}) do
    assert {200, %{"ok" => result}} = rpc(name, args)
    result
  end

  defp create_initiative!(name \\ nil, dirs \\ []) do
    name = name || "e2e-#{System.unique_integer([:positive])}"
    init = ok!("create_initiative", %{"name" => name, "dirs" => dirs})
    id = init["id"]
    on_exit(fn -> rpc("delete_initiative", %{"initiative_id" => id}) end)
    {id, init}
  end

  # ── Initiative lifecycle ─────────────────────────────────────────────────────

  describe "initiative lifecycle" do
    test "create → list → set_status → add_dir → delete round trip" do
      {id, init} = create_initiative!("e2e-lifecycle")
      assert init["name"] == "e2e-lifecycle"
      assert init["status"] == "planning" or is_binary(init["status"])

      # Shows up in the global list.
      ids = ok!("list_initiatives") |> Enum.map(& &1["id"])
      assert id in ids

      # Status transition persists.
      updated = ok!("set_initiative_status", %{"initiative_id" => id, "status" => "ongoing"})
      assert updated["status"] == "ongoing"

      # Adding a directory persists on the initiative.
      dir = System.tmp_dir!()
      with_dir = ok!("add_dir", %{"initiative_id" => id, "dir" => dir})
      assert Enum.any?(with_dir["dirs"], &(&1["path"] == Path.expand(dir)))

      # Deletion removes it from the store.
      assert %{"deleted" => ^id} = ok!("delete_initiative", %{"initiative_id" => id})
      refute id in (ok!("list_initiatives") |> Enum.map(& &1["id"]))
    end

    @tag :tmp_dir
    test "remove_dir un-links a directory and leaves it on disk", %{tmp_dir: tmp_dir} do
      {id, _} = create_initiative!()
      dir = Path.join(tmp_dir, "project")
      File.mkdir_p!(dir)

      ok!("add_dir", %{"initiative_id" => id, "dir" => dir})

      without = ok!("remove_dir", %{"initiative_id" => id, "dir" => dir})
      refute Enum.any?(without["dirs"], &(&1["path"] == dir))
      assert File.dir?(dir), "removing a dir must not touch the user's folder"

      # Idempotent: removing what is no longer there is not an error.
      assert %{"dirs" => []} = ok!("remove_dir", %{"initiative_id" => id, "dir" => dir})
    end

    @tag :tmp_dir
    test "git actions act on the worktree, never the source repo", %{tmp_dir: tmp_dir} do
      repo = GitRepo.init_with!(Path.join(tmp_dir, "repo"), %{"file.txt" => "one\n"})
      GitRepo.git(repo, ["config", "user.email", "test@test.com"])
      GitRepo.git(repo, ["config", "user.name", "Test"])

      {id, _} = create_initiative!()
      with_dir = ok!("add_dir", %{"initiative_id" => id, "dir" => repo, "worktree" => true})
      [entry] = with_dir["dirs"]
      wt = entry["worktree_path"]
      assert is_binary(wt), "expected a worktree to be created"

      # An agent edits inside the worktree, which is where it is started.
      File.write!(Path.join(wt, "file.txt"), "changed by the agent\n")

      # The UI only ever names the SOURCE path. Committing must still land in the
      # worktree — the whole reason DirEntry.resolve/2 sits in front of these.
      assert %{"sha" => sha, "dir" => ^wt} =
               ok!("git_commit", %{
                 "initiative_id" => id,
                 "dir" => repo,
                 "message" => "from the worktree"
               })

      assert is_binary(sha)

      # The commit is in the worktree's branch...
      {log, 0} = GitRepo.git(wt, ["log", "-1", "--format=%s"])
      assert String.trim(log) == "from the worktree"

      # ...and the user's own checkout was never touched.
      assert {"", 0} = GitRepo.git(repo, ["status", "--porcelain"])
      {source_log, 0} = GitRepo.git(repo, ["log", "-1", "--format=%s"])
      refute String.trim(source_log) == "from the worktree"
    end

    test "git_commit refuses an empty message" do
      {id, _} = create_initiative!()

      assert {422, %{"error" => msg}} =
               rpc("git_commit", %{"initiative_id" => id, "dir" => "/tmp", "message" => "  "})

      assert msg =~ "message is required"
    end

    test "a git action on an initiative with no repository says so" do
      {id, _} = create_initiative!()

      assert {422, %{"error" => msg}} = rpc("git_fetch", %{"initiative_id" => id})
      assert msg =~ "no git repository"
    end

    test "remove_dir on an unknown initiative returns a not-found error" do
      assert {422, %{"error" => msg}} =
               rpc("remove_dir", %{"initiative_id" => "does-not-exist", "dir" => "/tmp"})

      assert msg =~ "not found"
    end

    test "set_initiative_status rejects an invalid status" do
      {id, _} = create_initiative!()

      assert {422, %{"error" => msg}} =
               rpc("set_initiative_status", %{"initiative_id" => id, "status" => "bogus"})

      assert msg =~ "invalid status"
    end

    test "operations on an unknown initiative return a not-found error" do
      assert {422, %{"error" => msg}} = rpc("get_diff", %{"initiative_id" => "does-not-exist"})
      assert msg =~ "not found"
    end

    @tag :tmp_dir
    test "branch_initiative puts git directories on the initiative branch", %{tmp_dir: tmp_dir} do
      repo = GitRepo.init!(Path.join(tmp_dir, "repo"))
      plain = Path.join(tmp_dir, "plain")
      File.mkdir_p!(plain)

      {id, _} = create_initiative!("e2e-branching")
      ok!("add_dir", %{"initiative_id" => id, "dir" => repo})
      ok!("add_dir", %{"initiative_id" => id, "dir" => plain})

      assert %{"branch" => "codrift/e2e-branching", "switched" => [^repo], "skipped" => [skipped]} =
               ok!("branch_initiative", %{"initiative_id" => id})

      assert skipped["dir"] == plain
      assert Branch.current(repo) == "codrift/e2e-branching"

      # The dir now reports its branch back to the UI.
      assert [%{"branch" => "codrift/e2e-branching"}] =
               ok!("list_initiatives")
               |> Enum.find(&(&1["id"] == id))
               |> Map.fetch!("dirs")
               |> Enum.filter(&(&1["path"] == repo))
    end

    @tag :tmp_dir
    test "toggle_dir_branch refuses to move a dirty working tree", %{tmp_dir: tmp_dir} do
      repo = GitRepo.init!(Path.join(tmp_dir, "repo"))
      File.write!(Path.join(repo, "wip.txt"), "uncommitted")

      {id, _} = create_initiative!("e2e-dirty")
      ok!("add_dir", %{"initiative_id" => id, "dir" => repo})

      assert {422, %{"error" => msg}} =
               rpc("toggle_dir_branch", %{"initiative_id" => id, "dir" => repo})

      assert msg =~ "uncommitted changes"
    end
  end

  # ── Memory (SQLite FTS5) ─────────────────────────────────────────────────────

  describe "memory" do
    test "add → search → recent → list → delete full text round trip" do
      {id, _} = create_initiative!()

      %{"id" => rowid} =
        ok!("memory_add", %{
          "initiative_id" => id,
          "chunk_type" => "decision",
          "content" => "we use JWT tokens not server sessions"
        })

      assert is_integer(rowid)

      # FTS5 search finds it by term.
      hits = ok!("memory_search", %{"initiative_id" => id, "query" => "JWT"})
      assert Enum.any?(hits, &(&1["content"] =~ "JWT"))

      # recent + list surface it.
      assert Enum.any?(ok!("memory_recent", %{"initiative_id" => id}), &(&1["id"] == rowid))

      assert Enum.any?(
               ok!("memory_list", %{"initiative_id" => id, "chunk_type" => "decision"}),
               &(&1["id"] == rowid)
             )

      # Delete, then it's gone from search.
      assert %{"deleted" => ^rowid} =
               ok!("memory_delete", %{"initiative_id" => id, "id" => rowid})

      refute Enum.any?(
               ok!("memory_search", %{"initiative_id" => id, "query" => "JWT"}),
               &(&1["id"] == rowid)
             )
    end

    test "memory_add rejects an invalid chunk_type" do
      {id, _} = create_initiative!()

      assert {422, %{"error" => msg}} =
               rpc("memory_add", %{
                 "initiative_id" => id,
                 "chunk_type" => "nonsense",
                 "content" => "x"
               })

      assert msg =~ "invalid chunk_type"
    end

    test "memory_delete of a missing row returns not-found" do
      {id, _} = create_initiative!()

      assert {422, %{"error" => msg}} =
               rpc("memory_delete", %{"initiative_id" => id, "id" => 999_999})

      assert msg =~ "not found"
    end
  end

  # ── Context files, tree, and sandboxed read/write ────────────────────────────

  describe "files & tree" do
    @tag :tmp_dir
    test "list_tree, read_file, and write_file operate within initiative dirs", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "hello.txt"), "hi there")
      {id, _} = create_initiative!("e2e-files", [tmp_dir])

      # Tree lists the file relative to the dir.
      %{"dirs" => [%{"files" => files}]} = ok!("list_tree", %{"initiative_id" => id})
      assert "hello.txt" in files

      # Read returns its contents.
      assert %{"content" => "hi there"} =
               ok!("read_file", %{
                 "initiative_id" => id,
                 "path" => Path.join(tmp_dir, "hello.txt")
               })

      # Write lands on disk and reads back.
      target = Path.join(tmp_dir, "written.txt")

      assert %{"bytes" => 5} =
               ok!("write_file", %{"initiative_id" => id, "path" => target, "content" => "hello"})

      assert File.read!(target) == "hello"
    end

    @tag :tmp_dir
    test "read_file refuses paths outside the initiative's directories", %{tmp_dir: tmp_dir} do
      {id, _} = create_initiative!("e2e-escape", [tmp_dir])
      escape = Path.join(tmp_dir, "../../../../etc/passwd")

      assert {422, %{"error" => msg}} =
               rpc("read_file", %{"initiative_id" => id, "path" => escape})

      assert msg =~ "outside"
    end

    test "read_context_file rejects a name that traverses out of the folder" do
      {id, _} = create_initiative!()

      for name <- ["../secret", "docs/../../secret", "/etc/passwd"] do
        assert {422, %{"error" => msg}} =
                 rpc("read_context_file", %{"initiative_id" => id, "name" => name})

        assert msg =~ "invalid file name"
      end
    end

    test "context files include nested paths and hide Codrift's own bookkeeping" do
      {id, _} = create_initiative!("e2e-context-tree")
      context = Store.context_path(id)

      File.mkdir_p!(Path.join(context, "scripts"))
      File.write!(Path.join(context, "scripts/deploy.sh"), "#!/bin/sh\necho deploy\n")
      File.mkdir_p!(Path.join(context, ".agent-logs"))
      File.write!(Path.join(context, ".agent-logs/a.log"), "noise")
      File.write!(Path.join(context, "memory.db"), "binary")

      %{"files" => files} = ok!("list_context_files", %{"initiative_id" => id})

      assert "initiative.md" in files
      assert "scripts/deploy.sh" in files
      refute "memory.db" in files
      refute Enum.any?(files, &String.starts_with?(&1, "."))

      assert %{"content" => "#!/bin/sh\necho deploy\n"} =
               ok!("read_context_file", %{"initiative_id" => id, "name" => "scripts/deploy.sh"})
    end
  end

  # ── Diff against a real git repository ───────────────────────────────────────

  describe "diff" do
    @tag :tmp_dir
    test "get_diff surfaces an uncommitted change in a tracked file", %{tmp_dir: tmp_dir} do
      repo =
        GitRepo.init_with!(Path.join(tmp_dir, "repo"), %{
          "app.ex" => "defmodule App do\nend\n"
        })

      # Uncommitted modification.
      File.write!(Path.join(repo, "app.ex"), "defmodule App do\n  def run, do: :ok\nend\n")

      {id, _} = create_initiative!("e2e-diff", [repo])

      diffs = ok!("get_diff", %{"initiative_id" => id})
      assert Enum.any?(diffs, &(&1["path"] == "app.ex"))
    end
  end

  # ── Read-only config surfaces ────────────────────────────────────────────────

  describe "config surfaces" do
    test "get_keybindings returns the default binding map" do
      bindings = ok!("get_keybindings")
      assert is_map(bindings)
      assert map_size(bindings) > 0
      assert bindings["branch_initiative"] == "b"
    end

    test "get_oauth_status lists every supported service" do
      %{"services" => services} = ok!("get_oauth_status")
      assert %{"connected" => false, "flow" => "device_flow"} = services["github"]
      assert %{"connected" => false, "flow" => "pkce_browser"} = services["gitlab"]
      refute Map.has_key?(services, "notion")
      refute Map.has_key?(services, "jira")
    end
  end

  # ── Agent runtime: deterministic error paths ─────────────────────────────────

  describe "agent error paths" do
    test "send/stop/output on an unknown agent all report not-found" do
      assert {422, %{"error" => m1}} =
               rpc("send_to_agent", %{"agent_id" => "nope", "input" => "x"})

      assert m1 =~ "not found"
      assert {422, %{"error" => m2}} = rpc("stop_agent", %{"agent_id" => "nope"})
      assert m2 =~ "not found"
      assert {422, %{"error" => m3}} = rpc("get_agent_output", %{"agent_id" => "nope"})
      assert m3 =~ "not found"
    end

    test "broadcast_to_initiative with no running agents errors" do
      {id, _} = create_initiative!()

      assert {422, %{"error" => msg}} =
               rpc("broadcast_to_initiative", %{"initiative_id" => id, "input" => "hi"})

      assert msg =~ "no running agents"
    end
  end

  # ── Agent runtime: a live PTY agent driven end-to-end ────────────────────────

  describe "live agent (terminal adapter)" do
    @tag :tmp_dir
    test "start → send input → observe output → stop", %{tmp_dir: tmp_dir} do
      {id, _} = create_initiative!("e2e-agent")

      status =
        ok!("start_agent", %{"initiative_id" => id, "dir" => tmp_dir, "adapter" => "terminal"})

      agent_id = status["id"]
      assert is_binary(agent_id)
      on_exit(fn -> rpc("stop_agent", %{"agent_id" => agent_id}) end)

      # It appears among the initiative's running agents.
      assert Enum.any?(
               ok!("get_initiative_agents", %{"initiative_id" => id}),
               &(&1["id"] == agent_id)
             )

      # Type a command; the PTY echoes it and runs it, so the marker shows up
      # in buffered output. Poll (shell startup is asynchronous).
      marker = "CODRIFT_E2E_MARKER"
      _ = ok!("send_to_agent", %{"agent_id" => agent_id, "input" => "echo #{marker}\n"})

      assert eventually(fn ->
               %{"output" => chunks} =
                 ok!("get_agent_output", %{"agent_id" => agent_id, "n" => 200})

               chunks |> Enum.join() |> String.contains?(marker)
             end),
             "expected agent output to contain #{marker}"

      # Stop cleanly.
      assert %{"stopped" => ^agent_id} = ok!("stop_agent", %{"agent_id" => agent_id})
    end

    test "start_agent with no dir falls back to the initiative's scratchpad folder" do
      # A folderless initiative — no dirs configured.
      {id, init} = create_initiative!("e2e-scratch")
      assert init["dirs"] == []

      status = ok!("start_agent", %{"initiative_id" => id, "adapter" => "terminal"})
      agent_id = status["id"]
      on_exit(fn -> rpc("stop_agent", %{"agent_id" => agent_id}) end)

      # The agent runs in the initiative's context folder, which is now
      # registered as a directory so tree/diff/editor operate there too.
      scratch = Store.context_path(id)
      assert status["dir"] == scratch

      assert %{"dirs" => [%{"path" => ^scratch}]} =
               Enum.find(ok!("list_initiatives"), &(&1["id"] == id))
    end
  end

  describe "default agent" do
    setup do
      settings = Path.join(Codrift.Paths.data_dir(), "settings.json")
      previous = File.read(settings)

      on_exit(fn ->
        case previous do
          {:ok, content} -> File.write!(settings, content)
          {:error, _} -> File.rm_rf(settings)
        end
      end)

      :ok
    end

    test "the agent chosen at creation sticks to the initiative and seeds the next one" do
      init = ok!("create_initiative", %{"name" => "e2e-agent-pick", "agent" => "codex"})
      id = init["id"]
      on_exit(fn -> rpc("delete_initiative", %{"initiative_id" => id}) end)

      assert init["agent"] == "codex"
      assert %{"agent" => "codex"} = ok!("get_default_agent")

      {_other_id, other} = create_initiative!("e2e-agent-inherit")
      assert other["agent"] == nil

      assert %{"agent" => "claude"} =
               ok!("set_initiative_agent", %{"initiative_id" => id, "agent" => "claude"})

      assert %{"agent" => "claude"} = Enum.find(ok!("list_initiatives"), &(&1["id"] == id))
    end

    test "start_agent with no adapter resolves the initiative's agent, then the default" do
      ok!("save_agent_profile", %{"name" => "e2e-vanishing", "adapter" => "claude"})
      {id, _} = create_initiative!("e2e-agent-resolve")
      ok!("set_initiative_agent", %{"initiative_id" => id, "agent" => "e2e-vanishing"})

      ok!("save_agent_profile", %{"name" => "e2e-default-gone", "adapter" => "claude"})
      ok!("set_default_agent", %{"agent" => "e2e-default-gone"})
      {fallback_id, _} = create_initiative!("e2e-agent-fallback")

      ok!("delete_agent_profile", %{"name" => "e2e-vanishing"})
      ok!("delete_agent_profile", %{"name" => "e2e-default-gone"})

      assert {422, %{"error" => own}} = rpc("start_agent", %{"initiative_id" => id})
      assert own =~ "e2e-vanishing"

      assert {422, %{"error" => inherited}} =
               rpc("start_agent", %{"initiative_id" => fallback_id})

      assert inherited =~ "e2e-default-gone"
    end

    test "an unknown agent is rejected rather than stored" do
      assert {422, %{"error" => reason}} =
               rpc("create_initiative", %{"name" => "e2e-bad-agent", "agent" => "nope"})

      assert reason =~ "unknown agent"
    end
  end

  # Retries `fun` until it returns true or the deadline passes.
  defp eventually(fun, attempts \\ 60, sleep_ms \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: :timer.sleep(sleep_ms) && {:cont, false}
    end)
  end
end

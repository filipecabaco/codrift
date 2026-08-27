<script lang="ts">
  import { Icon } from "@steeze-ui/svelte-icon";
  import { Cog6Tooth } from "@steeze-ui/heroicons";
  import {
    fileUrl,
    isImagePath,
    rpc,
    openUrl,
    setInitiativeAgent,
    ADAPTERS,
    SERVICE_META,
    type Initiative,
    type Agent,
  } from "$lib/api";
  import { workspace as ws } from "$lib/workspace.svelte";
  import { MemoryIcon, WorktreeIcon, contextFileIcon, dirIcon } from "$lib/icons";
  import MemoryView from "$lib/MemoryView.svelte";
  import { markdownFor } from "$lib/markdown";
  import { highlightToHtml, langForPath } from "$lib/highlight";
  import { themeState } from "$lib/theme.svelte";

  let {
    initiative,
    agents = [],
    wantFile = null,
    wantPanel = "file",
    onChanged,
    onManageProfiles,
  }: {
    initiative: Initiative;
    agents: Agent[];
    wantFile?: string | null;
    /** Which half the sidebar asked for: a context document or the memory store. */
    wantPanel?: "file" | "memory";
    onChanged: () => void;
    onManageProfiles?: () => void;
  } = $props();

  let starting = $state<string | null>(null);
  let addingScratch = $state(false);
  let branching = $state<string | null>(null);
  let error = $state<string | null>(null);

  async function toggleBranch(dir: string) {
    branching = dir;
    error = null;
    try {
      await rpc("toggle_dir_branch", { initiative_id: initiative.id, dir });
      onChanged();
    } catch (e) {
      error = (e as Error).message;
    } finally {
      branching = null;
    }
  }

  const profiles = $derived(ws.profiles);
  const choice = $derived(ws.agentChoiceFor(initiative));

  // Resolve the selected choice into start_agent params: a profile passes its
  // base adapter plus its name; a bare adapter passes just itself.
  function launchParams(): { adapter: string; profile?: string } {
    const p = profiles.find((x) => x.name === choice);
    return p ? { adapter: p.adapter ?? "claude", profile: p.name } : { adapter: choice };
  }

  async function pickAgent(next: string) {
    error = null;
    try {
      await setInitiativeAgent(initiative.id, next);
      onChanged();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  const sourceLabel = (service: string) => SERVICE_META[service]?.label ?? service;

  const dirLabel = (path: string) =>
    path === initiative.context_path ? "scratch" : (path.split("/").pop() ?? path);

  /**
   * A worktree path is long and only its last two segments carry information —
   * every one of them lives under the same `<context>/worktrees/` folder, so the
   * prefix is the same for all of them and spending a row on it just pushes the
   * sentence off the end. The full paths are one hover away.
   */
  const tail = (path: string | undefined) =>
    path ? path.split("/").filter(Boolean).slice(-2).join("/") : "(being created…)";

  // Both ends spelled out, for the hover: where the agents are, and which
  // checkout is deliberately being left alone.
  const worktreeTitle = (dir: Initiative["dirs"][number]) =>
    `Isolated worktree — agents run here:\n${dir.worktree_path ?? "(being created…)"}` +
    `\n\nYour checkout, untouched:\n${dir.path}`;

  async function addScratch() {
    addingScratch = true;
    error = null;
    try {
      await rpc("add_context_workspace", { initiative_id: initiative.id });
      onChanged();
    } catch (e) {
      error = (e as Error).message;
    } finally {
      addingScratch = false;
    }
  }

  let files = $state<string[]>([]);
  let activeFile = $state<string | null>(null);
  let panel = $state<"file" | "memory">("file");
  let docHtml = $state<string>("");
  // The agent-facing half of initiative.md, rendered collapsed: agents read the
  // file, humans shouldn't have to re-read it every session.
  let agentNotesHtml = $state<string>("");
  let docError = $state<string | null>(null);

  const AGENT_NOTES =
    /<!--\s*codrift:agent-notes:start\s*-->([\s\S]*?)<!--\s*codrift:agent-notes:end\s*-->/;
  // Fallback for initiatives created before the markers existed.
  const LEGACY_NOTES = /^##\s+Memory Store[\s\S]*?(?=^##\s+(?!#)|\Z)/m;

  function splitDoc(markdown: string): { body: string; notes: string } {
    const marked = markdown.match(AGENT_NOTES);
    if (marked) return { body: markdown.replace(AGENT_NOTES, ""), notes: marked[1] };

    const legacy = markdown.match(LEGACY_NOTES);
    if (legacy) return { body: markdown.replace(LEGACY_NOTES, ""), notes: legacy[0] };

    return { body: markdown, notes: "" };
  }

  async function start(dir: string) {
    starting = dir;
    error = null;
    try {
      await rpc("start_agent", { initiative_id: initiative.id, dir, ...launchParams() });
      onChanged();
    } catch (e) {
      error = (e as Error).message;
    } finally {
      starting = null;
    }
  }

  // Context files for the selected initiative (initiative.md, orchestration.md…).
  $effect(() => {
    const id = initiative.id;
    files = [];
    activeFile = null;
    panel = "file";
    docHtml = "";
    rpc<{ files: string[] }>("list_context_files", { initiative_id: id })
      .then((res) => {
        files = res.files;
        activeFile = res.files.includes("initiative.md")
          ? "initiative.md"
          : (res.files[0] ?? null);
      })
      .catch((e) => (docError = (e as Error).message));
  });

  // Honour a file requested from the sidebar (overrides the initiative.md default).
  $effect(() => {
    const w = wantFile;
    if (w && files.includes(w)) {
      panel = "file";
      activeFile = w;
    }
  });

  // …and the panel, so the sidebar's `memory` row lands on the memory store.
  // Re-runs on an initiative switch too, otherwise the file effect above would
  // reset the panel while the sidebar still highlights `memory`.
  $effect(() => {
    initiative.id;
    panel = wantPanel;
  });

  // Everything in the folder used to be a markdown document, so everything was
  // parsed as one. A pinned file of interest (`open_file`) is whatever the agent
  // pointed at — source, JSON, a config — and markdown does real damage to that:
  // a leading `#` becomes a heading, indented lines become quoted blocks, and
  // what is left reads as prose. Anything that is not markdown gets syntax
  // highlighting instead, the same way the Tree pane previews it.
  const isMarkdown = (name: string) => /\.(md|markdown|mdx)$/i.test(name) || !name.includes(".");

  // An initiative folder holds whatever agents put in it, and screenshots are a
  // routine part of that. They are files like any other in the strip above, but
  // there is nothing to parse — the pane shows the picture instead.
  const activeImage = $derived(
    activeFile && isImagePath(activeFile) && initiative.context_path
      ? fileUrl(initiative.id, `${initiative.context_path}/${activeFile}`)
      : null,
  );

  // Render the selected context file as markdown.
  $effect(() => {
    const id = initiative.id;
    const name = activeFile;
    // Highlighted HTML has the old theme's colours baked in, so a re-skin has to
    // re-render it — the same reason the Tree pane's preview watches the theme.
    themeState.id;
    if (!name || (isImagePath(name) && initiative.context_path)) {
      docHtml = "";
      agentNotesHtml = "";
      return;
    }
    docError = null;
    rpc<{ content: string }>("read_context_file", { initiative_id: id, name })
      .then(async (res) => {
        if (!isMarkdown(name)) {
          docHtml = await highlightToHtml(res.content, langForPath(name));
          agentNotesHtml = "";
          return;
        }
        const { body, notes } = splitDoc(res.content);
        // Images resolve against the context folder, so a screenshot an agent
        // dropped next to initiative.md renders where the doc references it.
        const md = markdownFor(id, initiative.context_path ?? null);
        docHtml = md.parse(body) as string;
        agentNotesHtml = notes ? (md.parse(notes) as string) : "";
      })
      .catch((e) => {
        docError = (e as Error).message;
        docHtml = "";
        agentNotesHtml = "";
      });
  });
</script>

<div class="flex h-full flex-col">
  <!-- Identity + live state: what this initiative is and what's running right now. -->
  <header class="border-b border-border px-6 pt-4 pb-3">
    <div class="flex items-baseline gap-3">
      <h2 class="text-base font-semibold text-fg">{initiative.name}</h2>
      <span class="rounded-full border border-border px-2 py-0.5 text-[11px] text-muted">
        {initiative.status}
      </span>
      {#if initiative.integration}
        {@const source = initiative.integration}
        <button
          class="rounded-full border border-accent/40 px-2 py-0.5 text-[11px] text-accent disabled:opacity-70"
          title={source.url ?? `${sourceLabel(source.service)} ${source.item_id}`}
          disabled={!source.url}
          onclick={() => source.url && openUrl(source.url)}
        >
          {sourceLabel(source.service)} · {source.item_id}
        </button>
      {/if}
    </div>
    <div class="mt-1.5 text-[11px] text-muted">
      {initiative.dirs.length} director{initiative.dirs.length === 1 ? "y" : "ies"}
      · {agents.length} agent{agents.length === 1 ? "" : "s"} running
    </div>
  </header>

  <!-- Directories: the actionable surface (launch an agent per directory). -->
  <section class="border-b border-border px-6 py-3">
    <div class="mb-2 flex items-center justify-between gap-3">
      <span class="text-[11px] font-semibold tracking-wider text-muted uppercase">Directories</span>
      <div class="flex items-center gap-2">
        <label class="text-[11px] text-muted" for="adapter">Agent</label>
        <select
          id="adapter"
          value={choice}
          title="The agent this initiative starts. Profiles carry their own command and account."
          onchange={(e) => pickAgent(e.currentTarget.value)}
          class="rounded-md border border-border bg-canvas px-2 py-1 text-xs text-fg"
        >
          {#each ADAPTERS as a}
            <option value={a}>{a}</option>
          {/each}
          {#if profiles.length}
            <optgroup label="Profiles">
              {#each profiles as p (p.name)}
                <option value={p.name}>{p.name}</option>
              {/each}
            </optgroup>
          {/if}
        </select>
        <button
          class="rounded-md p-1 text-muted hover:text-fg"
          title="Manage launch profiles — add an agent with its own command and account"
          aria-label="Manage launch profiles"
          onclick={() => onManageProfiles?.()}
        >
          <Icon src={Cog6Tooth} class="size-3.5" />
        </button>
      </div>
    </div>
    {#if error}<p class="mb-2 text-xs text-red-400">{error}</p>{/if}
    <div class="space-y-0.5">
      {#each initiative.dirs as dir (dir.path)}
        <!-- Either path counts: an agent in a worktree-backed directory reports
             the worktree it runs in, not the source the user added. -->
        {@const dirAgents = agents.filter(
          (a) => a.dir === dir.path || a.dir === dir.worktree_path,
        ).length}
        <div class="flex items-center gap-3 rounded-md px-2 py-1.5 hover:bg-surface">
          <Icon
            src={dir.worktree_enabled ? WorktreeIcon : dirIcon(dir.git)}
            class={["size-4 shrink-0", dir.worktree_enabled ? "text-sky-400" : "text-muted"]}
            title={dir.worktree_enabled
              ? "Isolated worktree"
              : dir.git
                ? "Git repository"
                : "Folder (not a git repository)"}
          />
          <span class="min-w-0 flex-1 text-[13px] text-fg">
            <span class="block truncate" title={dir.path}>{dirLabel(dir.path)}</span>
            <!-- The sidebar has room for a badge and a tooltip; this view has
                 room for the answer itself. Both ends, spelled out: where the
                 agents are, and which checkout is being left alone. -->
            {#if dir.worktree_enabled}
              <span class="mt-0.5 block truncate text-[11px] text-muted" title={worktreeTitle(dir)}>
                agents run in <span class="text-sky-400/90">{tail(dir.worktree_path)}</span>
                · your checkout is untouched
              </span>
            {/if}
          </span>
          {#if dir.git && !dir.worktree_enabled}
            <button
              class={[
                "shrink-0 rounded border px-1.5 text-[11px]",
                dir.branch
                  ? "border-accent/40 text-accent"
                  : "border-border text-muted hover:text-fg",
              ]}
              title={dir.branch
                ? `On ${dir.branch} — click to stop tracking it`
                : "Check this directory out on a branch for this initiative"}
              disabled={branching === dir.path}
              onclick={() => toggleBranch(dir.path)}
            >
              {branching === dir.path ? "…" : (dir.branch ?? "branch")}
            </button>
          {/if}
          {#if dirAgents}<span class="text-[11px] text-muted">{dirAgents} running</span>{/if}
          <button
            class="shrink-0 rounded-md bg-accent/20 px-2.5 py-1 text-[11px] text-accent hover:bg-accent/30 disabled:opacity-50"
            disabled={starting === dir.path}
            onclick={() => start(dir.path)}
          >
            {starting === dir.path ? "starting…" : `start ${choice}`}
          </button>
        </div>
      {:else}
        <div class="flex flex-col items-start gap-1.5 py-1">
          <button
            class="rounded-md border border-dashed border-border px-3 py-1.5 text-xs text-muted hover:text-fg disabled:opacity-50"
            disabled={addingScratch}
            onclick={addScratch}
          >
            {addingScratch ? "…" : "+ Use this initiative's folder as a scratch workspace"}
          </button>
          <span class="text-[11px] text-muted">or add a directory with the {"a"} shortcut.</span>
        </div>
      {/each}
    </div>
  </section>

  <!-- An initiative folder can hold a whole handbook, so the strip scrolls
       rather than wrapping into a wall of tabs. -->
  <div class="flex gap-1 overflow-x-auto border-b border-border px-6 py-1.5">
    {#each files as f (f)}
      <button
        class={[
          "flex shrink-0 items-center gap-1 rounded px-2 py-0.5 text-xs",
          panel === "file" && activeFile === f ? "bg-accent/20 text-white" : "text-muted hover:text-fg",
        ]}
        title={f}
        onclick={() => {
          panel = "file";
          activeFile = f;
        }}
      >
        <Icon src={contextFileIcon(f)} class="size-3.5 shrink-0" />
        {f.split("/").pop()}
      </button>
    {/each}
    <button
      class={[
        "flex shrink-0 items-center gap-1 rounded px-2 py-0.5 text-xs",
        panel === "memory" ? "bg-accent/20 text-white" : "text-muted hover:text-fg",
      ]}
      onclick={() => (panel = "memory")}
    >
      <Icon src={MemoryIcon} class="size-3.5 shrink-0" />
      memory
    </button>
  </div>

  <div class="min-h-0 flex-1 overflow-hidden">
    {#if panel === "memory"}
      <MemoryView initiativeId={initiative.id} />
    {:else}
      <div class="h-full overflow-auto px-6 py-4">
        {#if docError}
          <p class="text-xs text-red-400">{docError}</p>
        {:else if activeImage}
          <img
            src={activeImage}
            alt={activeFile ?? "image"}
            class="mx-auto max-w-full rounded border border-border"
          />
        {:else if docHtml && activeFile && !isMarkdown(activeFile)}
          <!-- Shiki emits its own <pre>; the prose classes below would restyle it. -->
          <div class="text-[12px] leading-5 [&_pre]:m-0 [&_pre]:overflow-auto [&_pre]:bg-transparent [&_pre]:p-0">
            {@html docHtml}
          </div>
        {:else if docHtml}
          <div
            class="text-[13px] leading-6 [&_a]:text-accent [&_a]:underline [&_code]:rounded [&_code]:bg-surface [&_code]:px-1 [&_code]:py-0.5 [&_h1]:hidden [&_h2]:mt-5 [&_h2]:mb-2 [&_h2]:text-base [&_h2]:font-semibold [&_h2]:text-accent [&_h2:first-child]:mt-0 [&_h3]:mt-3 [&_h3]:mb-1 [&_h3]:font-semibold [&_img]:my-2 [&_img]:max-w-full [&_img]:rounded [&_img]:border [&_img]:border-border [&_li]:my-0.5 [&_p]:my-2 [&_pre]:my-2 [&_pre]:overflow-auto [&_pre]:rounded [&_pre]:bg-surface [&_pre]:p-3 [&_strong]:text-fg [&_ul]:my-2 [&_ul]:list-disc [&_ul]:pl-5"
          >
            {@html docHtml}
          </div>
          {#if agentNotesHtml}
            <details class="mt-6 border-t border-border pt-3">
              <summary class="cursor-pointer text-[11px] text-muted hover:text-fg">
                Agent instructions (memory store, MCP and CLI usage)
              </summary>
              <div
                class="mt-3 text-[13px] leading-6 text-fg/70 [&_code]:rounded [&_code]:bg-surface [&_code]:px-1 [&_code]:py-0.5 [&_h2]:mt-4 [&_h2]:mb-2 [&_h2]:text-sm [&_h2]:font-semibold [&_h2]:text-fg [&_h3]:mt-3 [&_h3]:mb-1 [&_h3]:font-semibold [&_p]:my-2 [&_pre]:my-2 [&_pre]:overflow-auto [&_pre]:rounded [&_pre]:bg-surface [&_pre]:p-3"
              >
                {@html agentNotesHtml}
              </div>
            </details>
          {/if}
        {:else}
          <p class="text-xs text-muted">No context file.</p>
        {/if}
      </div>
    {/if}
  </div>
</div>

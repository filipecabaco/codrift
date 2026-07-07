<script lang="ts">
  import { marked } from "marked";
  import {
    rpc,
    ADAPTERS,
    listAgentProfiles,
    type Initiative,
    type Agent,
    type AgentProfile,
  } from "$lib/api";
  import MemoryView from "$lib/MemoryView.svelte";

  let {
    initiative,
    agents = [],
    wantFile = null,
    onChanged,
  }: {
    initiative: Initiative;
    agents: Agent[];
    wantFile?: string | null;
    onChanged: () => void;
  } = $props();

  // The selected launch choice: either a base adapter name or a profile name.
  let choice = $state<string>("claude");
  let profiles = $state<AgentProfile[]>([]);
  let starting = $state<string | null>(null);
  let addingScratch = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    listAgentProfiles()
      .then((p) => (profiles = p))
      .catch(() => (profiles = []));
  });

  // Resolve the selected choice into start_agent params: a profile passes its
  // base adapter plus its name; a bare adapter passes just itself.
  function launchParams(): { adapter: string; profile?: string } {
    const p = profiles.find((x) => x.name === choice);
    return p ? { adapter: p.adapter ?? "claude", profile: p.name } : { adapter: choice };
  }

  const dirLabel = (path: string) =>
    path === initiative.context_path ? "scratch" : (path.split("/").pop() ?? path);

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
  let docError = $state<string | null>(null);

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

  // Render the selected context file as markdown.
  $effect(() => {
    const id = initiative.id;
    const name = activeFile;
    if (!name) {
      docHtml = "";
      return;
    }
    docError = null;
    rpc<{ content: string }>("read_context_file", { initiative_id: id, name })
      .then((res) => (docHtml = marked.parse(res.content) as string))
      .catch((e) => {
        docError = (e as Error).message;
        docHtml = "";
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
        <label class="text-[11px] text-muted" for="adapter">Launch</label>
        <select
          id="adapter"
          bind:value={choice}
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
      </div>
    </div>
    {#if error}<p class="mb-2 text-xs text-red-400">{error}</p>{/if}
    <div class="space-y-0.5">
      {#each initiative.dirs as dir (dir.path)}
        {@const dirAgents = agents.filter((a) => a.dir === dir.path).length}
        <div class="flex items-center gap-3 rounded-md px-2 py-1.5 hover:bg-surface">
          <span class="text-muted">▸</span>
          <span class="min-w-0 flex-1 truncate text-[13px] text-fg" title={dir.path}>
            {dirLabel(dir.path)}
          </span>
          {#if dir.worktree_enabled}<span class="rounded border border-border px-1.5 text-[11px] text-muted">worktree</span>{/if}
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

  <div class="flex gap-1 border-b border-border px-6 py-1.5">
    {#each files as f (f)}
      <button
        class={[
          "rounded px-2 py-0.5 text-xs",
          panel === "file" && activeFile === f ? "bg-accent/20 text-white" : "text-muted hover:text-fg",
        ]}
        onclick={() => {
          panel = "file";
          activeFile = f;
        }}
      >
        {f}
      </button>
    {/each}
    <button
      class={[
        "rounded px-2 py-0.5 text-xs",
        panel === "memory" ? "bg-accent/20 text-white" : "text-muted hover:text-fg",
      ]}
      onclick={() => (panel = "memory")}
    >
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
        {:else if docHtml}
          <div
            class="text-[13px] leading-6 [&_a]:text-accent [&_a]:underline [&_code]:rounded [&_code]:bg-surface [&_code]:px-1 [&_code]:py-0.5 [&_h1]:hidden [&_h2]:mt-5 [&_h2]:mb-2 [&_h2]:text-base [&_h2]:font-semibold [&_h2]:text-accent [&_h2:first-child]:mt-0 [&_h3]:mt-3 [&_h3]:mb-1 [&_h3]:font-semibold [&_li]:my-0.5 [&_p]:my-2 [&_pre]:my-2 [&_pre]:overflow-auto [&_pre]:rounded [&_pre]:bg-surface [&_pre]:p-3 [&_strong]:text-fg [&_ul]:my-2 [&_ul]:list-disc [&_ul]:pl-5"
          >
            {@html docHtml}
          </div>
        {:else}
          <p class="text-xs text-muted">No context file.</p>
        {/if}
      </div>
    {/if}
  </div>
</div>

<script lang="ts">
  // The initiative tree. Rows come from `workspace.rows`, so what renders and
  // what j/k walks are the same list.
  import { workspace as ws, isDead, needsInput, statusLabel } from "$lib/workspace.svelte";
  import type { Agent, Initiative } from "$lib/api";

  let {
    focused,
    width,
    newInitiativeKey,
    collapseKey,
    onSelectInitiative,
    onSelectDir,
    onSelectAgent,
    onOpenContextFile,
    onCollapse,
  }: {
    focused: boolean;
    width: number;
    newInitiativeKey: string;
    collapseKey: string;
    onSelectInitiative: (id: string) => void;
    onSelectDir: (initId: string, path: string) => void;
    onSelectAgent: (initId: string, agentId: string) => void;
    onOpenContextFile: (initId: string, name: string) => void;
    onCollapse: () => void;
  } = $props();

  const base = (p: string) => p.split("/").filter(Boolean).pop() ?? p;

  // Off the amber accent on purpose: amber means focus/selection, never state.
  const statusDot: Record<string, string> = {
    ongoing: "bg-green-500",
    planning: "bg-sky-500",
    done: "bg-violet-500",
    archived: "bg-muted",
  };

  const rowBase = "flex w-full items-center gap-1.5 rounded-md py-0.5 pr-1.5 text-left text-xs";
  const selected = (key: string) => ws.cursorKey === key;
</script>

<aside
  class={[
    "shrink-0 overflow-y-auto border-r bg-canvas p-2",
    focused ? "border-accent/50" : "border-border",
  ]}
  style="width: {width}px"
>
  <div class="mb-1 flex items-center justify-between pl-1">
    <span class="text-[10px] font-semibold uppercase tracking-wide text-muted">Initiatives</span>
    <button
      class="rounded p-0.5 text-muted hover:text-fg"
      title="Collapse sidebar ({collapseKey})"
      aria-label="Collapse sidebar"
      onclick={onCollapse}
    >‹</button>
  </div>

  {#if ws.loading}
    <p class="p-1.5 text-xs text-muted">Loading…</p>
  {:else if ws.error}
    <p class="p-1.5 text-xs text-red-400">{ws.error}</p>
  {:else if ws.initiatives.length === 0}
    <p class="p-1.5 text-xs text-muted">No initiatives yet. Press {newInitiativeKey} to create one.</p>
  {:else}
    <ul role="tree" aria-label="Initiatives" class="list-none">
      {#each ws.initiatives as init (init.id)}
        {@const open = ws.expanded.has(init.id)}
        {@const waiting = ws.waitingCount(init.id)}
        <li role="none" class="mb-1">
          <div role="treeitem" aria-expanded={open} aria-selected={selected(`i:${init.id}`)} class="flex items-center">
            <button
              class="px-1 text-[10px] text-muted hover:text-fg"
              onclick={() => ws.toggleExpand(init.id)}
              aria-label={open ? `Collapse ${init.name}` : `Expand ${init.name}`}
            >
              {open ? "▾" : "▸"}
            </button>
            <button
              class={[
                "flex flex-1 items-center gap-1.5 rounded-md px-1 py-1 text-left text-xs font-semibold",
                selected(`i:${init.id}`) ? "bg-accent/20 text-white" : "text-fg hover:bg-surface",
              ]}
              onclick={() => onSelectInitiative(init.id)}
            >
              <span class={["size-2 rounded-full", statusDot[init.status] ?? "bg-muted"]}></span>
              <span class="truncate">{init.name}</span>
              <!-- A collapsed initiative still has to say someone inside is blocked. -->
              {#if waiting}
                <span class="ml-auto rounded bg-accent/20 px-1 text-[10px] font-semibold text-accent">
                  {waiting} waiting
                </span>
              {:else if ws.agentsFor(init.id).length}
                <span class="ml-auto text-[11px] text-muted">{ws.agentsFor(init.id).length}</span>
              {/if}
            </button>
          </div>

          {#if open}
            <ul role="group" class="list-none">
              {#each ws.contextFiles[init.id] ?? [] as f (f)}
                <li role="none">
                  <button
                    role="treeitem"
                    aria-selected={selected(`f:${init.id}:${f}`)}
                    class={[
                      rowBase,
                      "pl-6",
                      selected(`f:${init.id}:${f}`) ? "bg-accent/20 text-white" : "text-fg/70 hover:bg-surface",
                    ]}
                    onclick={() => onOpenContextFile(init.id, f)}
                  >
                    <span class="text-muted">◈</span>{f}
                  </button>
                </li>
              {/each}

              {#each init.dirs as dir (dir.path)}
                <li role="none">
                  <button
                    role="treeitem"
                    aria-selected={selected(`d:${init.id}:${dir.path}`)}
                    class={[
                      rowBase,
                      "pl-6",
                      selected(`d:${init.id}:${dir.path}`) ? "bg-accent/20 text-white" : "text-fg/80 hover:bg-surface",
                    ]}
                    onclick={() => onSelectDir(init.id, dir.path)}
                    title={dir.path}
                  >
                    <span class="text-muted">◇</span>
                    <span class="truncate">
                      {dir.path === init.context_path ? "scratch" : base(dir.path)}
                    </span>
                    {#if dir.worktree_enabled}
                      <span class="rounded border border-border px-1 text-[10px] text-muted">wt</span>
                    {/if}
                  </button>
                </li>
                {#each ws.agentsForDir(init.id, dir.path) as agent (agent.id)}
                  {@render agentRow(init, agent, "pl-10")}
                {/each}
              {/each}

              {#each ws.looseAgents(init) as agent (agent.id)}
                {@render agentRow(init, agent, "pl-6")}
              {/each}
            </ul>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</aside>

{#snippet agentRow(init: Initiative, agent: Agent, indent: string)}
  {@const key = `a:${agent.id}`}
  <li role="none">
    <button
      role="treeitem"
      aria-selected={selected(key)}
      class={[
        rowBase,
        indent,
        "gap-2",
        selected(key) ? "bg-accent/20 text-white" : "text-fg/70 hover:bg-surface",
      ]}
      onclick={() => onSelectAgent(init.id, agent.id)}
    >
      <span class={needsInput(agent.status) ? "text-accent" : "text-muted"}>◦</span>
      <span class="truncate">{agent.adapter}</span>
      {#if agent.profile}
        <span class="rounded border border-accent/40 px-1 text-[10px] text-accent/90">{agent.profile}</span>
      {/if}
      <!-- Text first; colour only reinforces it. -->
      <span
        class={[
          "ml-auto shrink-0 text-[11px]",
          needsInput(agent.status)
            ? "rounded bg-accent/20 px-1 font-semibold text-accent"
            : isDead(agent.status)
              ? "text-red-300/80"
              : "text-fg/60",
        ]}
      >
        {statusLabel(agent.status)}
      </span>
    </button>
  </li>
{/snippet}

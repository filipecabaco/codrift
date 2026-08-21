<script lang="ts">
  // The initiative tree. Rows come from `workspace.rows`, so what renders and
  // what j/k walks are the same list.
  import { Icon } from "@steeze-ui/svelte-icon";
  import { workspace as ws, isDead, needsInput, statusLabel } from "$lib/workspace.svelte";
  import {
    AgentIcon,
    FolderIcon,
    FolderOpenIcon,
    InitiativeIcon,
    MemoryIcon,
    TerminalAgentIcon,
    contextFileIcon,
    dirIcon,
  } from "$lib/icons";
  import type { Agent, Initiative } from "$lib/api";

  let {
    focused,
    width,
    paneStrips,
    onSelectPane,
    newInitiativeKey,
    collapseKey,
    onSelectInitiative,
    onSelectDir,
    onSelectAgent,
    onOpenContextFile,
    onOpenMemory,
    onToggleContextFolder,
    onCollapse,
  }: {
    focused: boolean;
    width: number;
    /** Open panes per initiative, for initiatives that currently have a split. */
    paneStrips: Record<
      string,
      { label: string; kind: "terminal" | "agent" | "view"; active: boolean }[]
    >;
    onSelectPane: (initId: string, idx: number) => void;
    newInitiativeKey: string;
    collapseKey: string;
    onSelectInitiative: (id: string) => void;
    onSelectDir: (initId: string, path: string) => void;
    onSelectAgent: (initId: string, agentId: string) => void;
    onOpenContextFile: (initId: string, name: string) => void;
    onOpenMemory: (initId: string) => void;
    onToggleContextFolder: (initId: string, path: string) => void;
    onCollapse: () => void;
  } = $props();

  const base = (p: string) => p.split("/").filter(Boolean).pop() ?? p;

  // Status colours the initiative icon rather than a separate dot: one glyph
  // says both *what* the row is and *where* it stands. Off the amber accent on
  // purpose — amber means focus/selection, never state.
  const statusColor: Record<string, string> = {
    ongoing: "text-green-500",
    planning: "text-sky-500",
    done: "text-violet-500",
    archived: "text-muted",
  };

  const rowBase = "flex w-full items-center gap-1.5 rounded-md py-0.5 pr-1.5 text-left text-xs";
  const selected = (key: string) => ws.cursorKey === key;
</script>

<aside
  class={[
    // overflow-x-hidden is not redundant: CSS resolves a `visible` axis to
    // `auto` when the other axis is not visible, so `overflow-y-auto` alone gave
    // the sidebar a horizontal scrollbar the moment any row outgrew it — and that
    // scrollbar then ate 15px of vertical room off the bottom of the list.
    "shrink-0 overflow-x-hidden overflow-y-auto border-r bg-canvas p-2",
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
                // min-w-0 is what makes the truncate below work. `flex-1` sets
                // the basis but not the floor: a flex item's default min-width is
                // auto — its min-content width — so a long initiative name pushed
                // the whole row wider than the sidebar instead of ellipsing.
                "flex min-w-0 flex-1 items-center gap-1.5 rounded-md px-1 py-1 text-left text-xs font-semibold",
                selected(`i:${init.id}`) ? "bg-accent/20 text-white" : "text-fg hover:bg-surface",
              ]}
              onclick={() => onSelectInitiative(init.id)}
            >
              <Icon
                src={InitiativeIcon}
                class={["size-3.5 shrink-0", statusColor[init.status] ?? "text-muted"]}
                title="Initiative · {init.status}"
              />
              <span class="min-w-0 flex-1 truncate">{init.name}</span>
              <!-- A collapsed initiative still has to say someone inside is blocked. -->
              {#if waiting}
                <span class="shrink-0 rounded bg-accent/20 px-1 text-[10px] font-semibold whitespace-nowrap text-accent">
                  {waiting} waiting
                </span>
              {:else if ws.agentsFor(init.id).length}
                <span class="shrink-0 text-[11px] text-muted">{ws.agentsFor(init.id).length}</span>
              {/if}
            </button>
          </div>

          <!-- The initiative's open panes. Drawn whether or not the initiative
               is expanded, and whether or not it is the one on screen: this row
               is how you find out that the initiative below has a split waiting
               for you, which is the whole reason layouts are kept per
               initiative rather than per window. -->
          {#if paneStrips[init.id]}
            <div class="flex items-center gap-1 py-0.5 pl-6 pr-1" role="group" aria-label="Open panes">
              {#each paneStrips[init.id] as chip, i}
                <button
                  class={[
                    "flex min-w-0 flex-1 items-center gap-1 rounded border px-1 py-px text-[10px]",
                    chip.active
                      ? "border-accent/50 bg-accent/20 text-white"
                      : "border-border bg-surface text-muted hover:text-fg",
                  ]}
                  title="Pane {i + 1}: {chip.label}"
                  onclick={() => onSelectPane(init.id, i)}
                >
                  {#if chip.kind !== "view"}
                    <Icon
                      src={chip.kind === "terminal" ? TerminalAgentIcon : AgentIcon}
                      class="size-2.5 shrink-0"
                      title={chip.kind === "terminal" ? "Terminal" : "Agent"}
                    />
                  {/if}
                  <span class="min-w-0 truncate">{chip.label}</span>
                </button>
              {/each}
            </div>
          {/if}

          {#if open}
            <ul role="group" class="list-none">
              <!-- The initiative folder, as it actually is on disk: docs at the
                   root, plus whatever scripts/ and docs/ the user keeps there. -->
              {#each ws.contextRows(init.id) as { node, depth } (node.path)}
                {@const key = node.isFile ? `f:${init.id}:${node.path}` : `x:${init.id}:${node.path}`}
                {@const folderOpen = ws.folderOpen(init.id, node.path)}
                <li role="none">
                  <button
                    role="treeitem"
                    aria-selected={selected(key)}
                    aria-expanded={node.isFile ? undefined : folderOpen}
                    aria-level={depth + 2}
                    class={[
                      rowBase,
                      selected(key) ? "bg-accent/20 text-white" : "text-fg/70 hover:bg-surface",
                    ]}
                    style="padding-left: {depth * 12 + 24}px"
                    title={node.path}
                    onclick={() =>
                      node.isFile
                        ? onOpenContextFile(init.id, node.path)
                        : onToggleContextFolder(init.id, node.path)}
                  >
                    <Icon
                      src={node.isFile
                        ? contextFileIcon(node.path)
                        : folderOpen
                          ? FolderOpenIcon
                          : FolderIcon}
                      class="size-3.5 shrink-0 text-muted"
                    />
                    <span class="truncate">{node.name}</span>
                  </button>
                </li>
              {/each}

              <li role="none">
                <button
                  role="treeitem"
                  aria-selected={selected(`m:${init.id}`)}
                  class={[
                    rowBase,
                    "pl-6",
                    selected(`m:${init.id}`) ? "bg-accent/20 text-white" : "text-fg/70 hover:bg-surface",
                  ]}
                  onclick={() => onOpenMemory(init.id)}
                >
                  <Icon src={MemoryIcon} class="size-3.5 shrink-0 text-muted" />
                  <span class="truncate">memory</span>
                </button>
              </li>

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
                    <!-- A repo and a plain folder are different things to work
                         in: one has a diff, the other doesn't. -->
                    <Icon
                      src={dirIcon(dir.git)}
                      class="size-3.5 shrink-0 text-muted"
                      title={dir.git ? "Git repository" : "Folder (not a git repository)"}
                    />
                    <span class="min-w-0 flex-1 truncate">
                      {dir.path === init.context_path ? "scratch" : base(dir.path)}
                    </span>
                    {#if dir.worktree_enabled}
                      <span class="shrink-0 rounded border border-border px-1 text-[10px] text-muted">wt</span>
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
      <Icon
        src={agent.adapter === "terminal" ? TerminalAgentIcon : AgentIcon}
        class={["size-3.5 shrink-0", needsInput(agent.status) ? "text-accent" : "text-muted"]}
      />
      <!-- Adapter, profile and status compete for a narrow sidebar. The adapter
           and the status are short and fixed, so the user-named profile is the
           one that gives way — on its own line, never wrapping the row. -->
      <span class="shrink-0">{agent.adapter}</span>
      {#if agent.profile}
        <span
          class="min-w-0 flex-1 truncate rounded border border-accent/40 px-1 text-[10px] whitespace-nowrap text-accent/90"
          title={agent.profile}
        >{agent.profile}</span>
      {/if}
      <!-- Text first; colour only reinforces it. -->
      <span
        class={[
          "ml-auto shrink-0 text-[11px] whitespace-nowrap",
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

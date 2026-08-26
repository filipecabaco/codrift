<script lang="ts" module>
  /**
   * What a right-click in the sidebar landed on.
   *
   * The sidebar reports the target and stops there — App.svelte owns every
   * command a menu could offer, so building the menu here would mean either
   * duplicating those handlers or threading a dozen more callbacks through.
   */
  export type SidebarTarget =
    | { kind: "initiative"; initId: string }
    | { kind: "dir"; initId: string; path: string }
    | { kind: "agent"; initId: string; agentId: string }
    | { kind: "file"; initId: string; path: string; isFile: boolean }
    | { kind: "memory"; initId: string };
</script>

<script lang="ts">
  // The initiative tree. Rows come from `workspace.rows`, so what renders and
  // what j/k walks are the same list.
  import { Icon } from "@steeze-ui/svelte-icon";
  import {
    workspace as ws,
    agentIconLabel,
    isDead,
    isOrchestrated,
    needsInput,
    statusLabel,
  } from "$lib/workspace.svelte";
  import {
    FolderIcon,
    FolderOpenIcon,
    InitiativeIcon,
    MemoryIcon,
    PromoteIcon,
    ScratchpadIcon,
    WorktreeIcon,
    agentIcon,
    contextFileIcon,
    dirIcon,
  } from "$lib/icons";
  import { SIDEBAR_SORTS, type Agent, type Initiative } from "$lib/api";

  let {
    focused,
    width,
    paneStrips,
    onSelectPane,
    newInitiativeKey,
    newScratchpadKey,
    collapseKey,
    onSelectInitiative,
    onPromote,
    onSelectDir,
    onSelectAgent,
    onOpenContextFile,
    onOpenMemory,
    onToggleContextFolder,
    onContextMenu,
    onCollapse,
  }: {
    focused: boolean;
    width: number;
    /** Open panes per initiative, for initiatives that currently have a split. */
    paneStrips: Record<
      string,
      {
        label: string;
        kind: "terminal" | "agent" | "view";
        active: boolean;
        role?: string | null;
      }[]
    >;
    onSelectPane: (initId: string, idx: number) => void;
    newInitiativeKey: string;
    newScratchpadKey: string;
    collapseKey: string;
    onSelectInitiative: (id: string) => void;
    /** Rank a scratchpad up into a real initiative. */
    onPromote: (id: string) => void;
    onSelectDir: (initId: string, path: string) => void;
    onSelectAgent: (initId: string, agentId: string) => void;
    onOpenContextFile: (initId: string, name: string) => void;
    onOpenMemory: (initId: string) => void;
    onToggleContextFolder: (initId: string, path: string) => void;
    onContextMenu: (event: MouseEvent, target: SidebarTarget) => void;
    onCollapse: () => void;
  } = $props();

  const base = (p: string) => p.split("/").filter(Boolean).pop() ?? p;

  /**
   * Both ends of the isolation, in the one place there is room for them.
   *
   * A `wt` chip on its own answers *that* a directory is isolated without
   * answering from what, or where to — and "where to" is the thing you need the
   * moment you want to `cd` there, or work out why your own checkout is not
   * changing while an agent is clearly busy.
   */
  const worktreeTitle = (dir: Initiative["dirs"][number]) =>
    `Isolated worktree — agents run here:\n${dir.worktree_path ?? "(being created…)"}` +
    `\n\nYour checkout, untouched:\n${dir.path}`;

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

  // Cycles rather than opening a menu: four options is few enough that stepping
  // through them costs less than a popover, and the label always says where you
  // are. The palette carries the same four by name, for going straight to one.
  const nextSort = $derived(
    SIDEBAR_SORTS[(SIDEBAR_SORTS.findIndex((s) => s.id === ws.sort) + 1) % SIDEBAR_SORTS.length],
  );
  const sortLabel = $derived(SIDEBAR_SORTS.find((s) => s.id === ws.sort)?.label ?? "created");
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
  <div class="mb-1 flex items-center gap-1 pl-1">
    <span class="text-[10px] font-semibold uppercase tracking-wide text-muted">Initiatives</span>
    <!-- Says what the order *is*, not just that ordering exists — the label is
         the state readout and the control at once, which is the only way this
         fits in a 10px header row. -->
    <button
      class="ml-auto rounded px-1 text-[10px] lowercase text-muted hover:bg-surface hover:text-fg"
      title="Sorted by {sortLabel} — click for {nextSort.label}"
      aria-label="Sort initiatives, currently by {sortLabel}"
      onclick={() => ws.setSort(nextSort.id)}
    >⇅ {sortLabel}</button>
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
    <p class="p-1.5 text-xs text-muted">
      No initiatives yet. Press {newInitiativeKey} to create one, or {newScratchpadKey} for a
      scratchpad you can name later.
    </p>
  {:else}
    <ul role="tree" aria-label="Initiatives" class="list-none">
      {#each ws.projects as init (init.id)}
        {@render initiativeItem(init)}
      {/each}
    </ul>

    <!-- Scratchpads live under their own heading rather than mixed into the
         list: they are opened faster than they are named, so without a wall
         between them the filed work would end up outnumbered by the throwaway
         sessions in the one view that is supposed to show what you are on. -->
    {#if ws.scratchpads.length}
      <div class="mt-3 mb-1 flex items-center justify-between pl-1">
        <span class="text-[10px] font-semibold uppercase tracking-wide text-muted">Scratchpads</span>
        <span class="pr-1 text-[10px] text-muted" title="Open a scratchpad">{newScratchpadKey}</span>
      </div>
      <ul role="tree" aria-label="Scratchpads" class="list-none">
        {#each ws.scratchpads as init (init.id)}
          {@render initiativeItem(init)}
        {/each}
      </ul>
    {/if}
  {/if}
</aside>

{#snippet initiativeItem(init: Initiative)}
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
                "flex min-w-0 flex-1 items-center gap-1.5 rounded-md px-1 py-1 text-left text-xs",
                // A scratchpad's name is a timestamp, not a title — setting it
                // in the same weight as filed work would overstate it.
                init.scratch ? "font-normal text-fg/80" : "font-semibold text-fg",
                selected(`i:${init.id}`) ? "bg-accent/20 text-white" : "hover:bg-surface",
              ]}
              onclick={() => onSelectInitiative(init.id)}
              oncontextmenu={(e) => onContextMenu(e, { kind: "initiative", initId: init.id })}
            >
              <Icon
                src={init.scratch ? ScratchpadIcon : InitiativeIcon}
                class={["size-3.5 shrink-0", init.scratch ? "text-muted" : statusColor[init.status] ?? "text-muted"]}
                title={init.scratch ? "Scratchpad — not filed as an initiative yet" : `Initiative · ${init.status}`}
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
            <!-- Rank up. Sits on the row rather than in a menu because the
                 moment you know a scratch session is real work is the moment
                 you are looking at it, and a detour to name it there is how it
                 stays a scratch session forever. -->
            {#if init.scratch}
              <button
                class="shrink-0 rounded p-0.5 text-muted hover:text-accent"
                title="Rank up to an initiative"
                aria-label="Rank {init.name} up to an initiative"
                onclick={() => onPromote(init.id)}
              >
                <Icon src={PromoteIcon} class="size-3.5" />
              </button>
            {/if}
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
                    {@const chipAdapter = chip.kind === "terminal" ? "terminal" : "agent"}
                    <Icon
                      src={agentIcon(chipAdapter, chip.role)}
                      class="size-2.5 shrink-0"
                      title={agentIconLabel(chipAdapter, chip.role)}
                    />
                  {/if}
                  <span class="min-w-0 truncate">{chip.label}</span>
                </button>
              {/each}
            </div>
          {/if}

          {#if open}
            <ul role="group" class="list-none">
              <!-- Mirrors the `!i.scratch` branch in workspace.rows exactly: a
                   row drawn here that the cursor cannot walk (or vice versa) is
                   how the highlight ends up pointing at something the content
                   pane is not showing. -->
              {#if !init.scratch}
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
                    oncontextmenu={(e) =>
                      onContextMenu(e, {
                        kind: "file",
                        initId: init.id,
                        path: node.path,
                        isFile: node.isFile,
                      })}
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
                  oncontextmenu={(e) => onContextMenu(e, { kind: "memory", initId: init.id })}
                >
                  <Icon src={MemoryIcon} class="size-3.5 shrink-0 text-muted" />
                  <span class="truncate">memory</span>
                </button>
              </li>
              {/if}

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
                    oncontextmenu={(e) =>
                      onContextMenu(e, { kind: "dir", initId: init.id, path: dir.path })}
                    title={dir.worktree_enabled ? worktreeTitle(dir) : dir.path}
                  >
                    <!-- A repo, a plain folder and an isolated worktree are
                         three different things to work in: one has a diff, one
                         doesn't, and one is not the checkout you are looking at.
                         The last is worth its own glyph — a badge alone is easy
                         to read past, and reading past this one means believing
                         an agent is editing files it is not touching. -->
                    <Icon
                      src={dir.worktree_enabled ? WorktreeIcon : dirIcon(dir.git)}
                      class={["size-3.5 shrink-0", dir.worktree_enabled ? "text-sky-400" : "text-muted"]}
                      title={dir.worktree_enabled
                        ? "Isolated worktree"
                        : dir.git
                          ? "Git repository"
                          : "Folder (not a git repository)"}
                    />
                    <span class="min-w-0 flex-1 truncate">
                      {dir.path === init.context_path ? "scratch" : base(dir.path)}
                    </span>
                    {#if dir.worktree_enabled}
                      <!-- Sky, not the amber accent: amber means focus and
                           selection in this sidebar, never state. -->
                      <span class="shrink-0 rounded border border-sky-500/40 px-1 text-[10px] text-sky-400">wt</span>
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
{/snippet}

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
      oncontextmenu={(e) =>
        onContextMenu(e, { kind: "agent", initId: init.id, agentId: agent.id })}
    >
      <!-- Role decides the glyph, and only then the adapter: who is driving an
           agent is the one thing the row cannot say in words, whereas the
           adapter is written immediately to its right. The amber is left to
           mean exactly one thing — blocked on you — so an orchestrated agent
           that is *not* blocked is lifted a step out of the muted grey
           instead. -->
      <Icon
        src={agentIcon(agent.adapter, agent.role)}
        title={agentIconLabel(agent.adapter, agent.role)}
        class={[
          "size-3.5 shrink-0",
          needsInput(agent.status)
            ? "text-accent"
            : isOrchestrated(agent.role)
              ? "text-fg/70"
              : "text-muted",
        ]}
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

<script lang="ts">
  import Overlay from "$lib/Overlay.svelte";
  import { fuzzyMatch, highlight } from "$lib/fuzzy";
  import { workspace as ws } from "$lib/workspace.svelte";
  import {
    listAssignedItems,
    importFromIntegration,
    ADAPTERS,
    SERVICE_META,
    type AssignedItem,
    type IntegrationError,
  } from "$lib/api";
  import { authorize } from "$lib/oauth";

  let {
    onCreate,
    onOpen,
    onClose,
    onManageProfiles,
  }: {
    onCreate: (name: string, agent: string) => void;
    onOpen: (initiativeId: string) => void;
    onClose: () => void;
    onManageProfiles?: () => void;
  } = $props();

  let agent = $state(ws.agentChoiceFor(null));

  let query = $state("");
  let cursor = $state(0);
  let listEl = $state<HTMLElement | null>(null);
  let loading = $state(true);
  let items = $state<AssignedItem[]>([]);
  let errors = $state<IntegrationError[]>([]);
  // Service whose Reconnect button is mid-flow, and the message if it failed.
  let reconnecting = $state<string | null>(null);
  let reconnectError = $state<string | null>(null);
  let busy = $state<string | null>(null);
  let failure = $state<string | null>(null);
  let input: HTMLInputElement;

  const RELATIONS = ["all", "assigned", "created"] as const;
  let relation = $state<(typeof RELATIONS)[number]>("all");

  const key = (i: AssignedItem) => `${i.service}:${i.id}`;
  const label = (svc: string) => SERVICE_META[svc]?.label ?? svc;

  const inScope = $derived(
    relation === "all" ? items : items.filter((i) => i.relation === relation),
  );

  // Fuzzy over "<service> <id> <title>" so "lin949" and "rjwt" both land, then
  // rank by score. With no query the server order stands: assigned work first.
  const filtered = $derived(
    query.trim()
      ? inScope
          .map((item) => {
            const match = fuzzyMatch(`${label(item.service)} ${item.id} ${item.title}`, query);
            return match ? { item, match } : null;
          })
          .filter((row) => row !== null)
          .sort((a, b) => b!.match.score - a!.match.score)
          .map((row) => row!.item)
      : inScope,
  );

  const rows = $derived(filtered.length + 1);

  function titleRuns(item: AssignedItem) {
    const match = query.trim() ? fuzzyMatch(item.title, query) : null;
    return highlight(item.title, match?.positions ?? []);
  }

  function cycleRelation() {
    relation = RELATIONS[(RELATIONS.indexOf(relation) + 1) % RELATIONS.length];
    cursor = 0;
  }

  $effect(() => {
    input?.focus();
  });

  $effect(() => {
    query;
    cursor = 0;
  });

  $effect(() => {
    listEl?.querySelector<HTMLElement>(`[data-index="${cursor}"]`)?.scrollIntoView({ block: "nearest" });
  });

  async function loadWork() {
    loading = true;
    try {
      const res = await listAssignedItems();
      items = res.items;
      errors = res.errors;
    } catch (e) {
      failure = (e as Error).message;
    } finally {
      loading = false;
    }
  }
  void loadWork();

  // A 24-hour Linear token means an expired session is the ordinary case, not an
  // exceptional one — so the fix lives here, next to the work it is blocking,
  // rather than behind a trip to the Integrations panel.
  async function reconnect(service: string) {
    reconnectError = null;
    reconnecting = service;
    try {
      await authorize(service);
      await loadWork();
    } catch (e) {
      reconnectError = (e as Error).message;
    } finally {
      reconnecting = null;
    }
  }

  async function choose(row: number) {
    if (row === 0) {
      const name = query.trim();
      if (name) onCreate(name, agent);
      return;
    }

    const item = filtered[row - 1];
    if (!item || busy) return;

    if (item.initiative_id) {
      onOpen(item.initiative_id);
      return;
    }

    failure = null;
    busy = key(item);
    try {
      const initiative = await importFromIntegration(item.service, item.id);
      onOpen(initiative.id);
    } catch (e) {
      failure = (e as Error).message;
      busy = null;
    }
  }

  function onkeydown(e: KeyboardEvent) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      cursor = Math.min(cursor + 1, rows - 1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      cursor = Math.max(cursor - 1, 0);
    } else if (e.key === "Tab") {
      e.preventDefault();
      cycleRelation();
    } else if (e.key === "Enter") {
      e.preventDefault();
      choose(cursor);
    }
  }
</script>

<Overlay label="New initiative" width="600px" top="10vh" padded={false} ownsTab {onClose}>
  <input
    bind:this={input}
    bind:value={query}
    {onkeydown}
    name="initiative"
    aria-label="Initiative name or search your work"
    placeholder="Name a new initiative, or search your work below…"
    class="w-full border-b border-border bg-canvas px-3 py-2.5 text-sm text-fg outline-none"
  />

  <div class="flex items-center gap-2 border-b border-border px-3 py-2">
    <label class="text-[11px] text-muted" for="new-initiative-agent">Agent</label>
    <select
      id="new-initiative-agent"
      bind:value={agent}
      title="Which agent this initiative starts. Changeable later with the p key, or from the Context view."
      class="rounded-md border border-border bg-canvas px-2 py-1 text-xs text-fg"
    >
      {#each ADAPTERS as a (a)}
        <option value={a}>{a}</option>
      {/each}
      {#if ws.profiles.length}
        <optgroup label="Profiles">
          {#each ws.profiles as p (p.name)}
            <option value={p.name}>{p.name}</option>
          {/each}
        </optgroup>
      {/if}
    </select>
    <button
      class="text-[11px] text-accent hover:underline"
      onclick={() => onManageProfiles?.()}
    >
      manage profiles
    </button>
    <span class="ml-auto text-[11px] text-muted">also the default for the next one</span>
  </div>

  {#if failure}
    <p class="border-b border-red-500/30 bg-red-500/10 px-3 py-2 text-[11px] text-red-300">
      {failure}
    </p>
  {/if}

  <ul bind:this={listEl} class="max-h-[60vh] overflow-y-auto py-1">
    <li>
      <button
        data-index={0}
        class={[
          "flex w-full items-center gap-2 px-3 py-2 text-left text-[13px]",
          cursor === 0 ? "bg-accent/20 text-white" : "text-fg/90",
        ]}
        onmouseenter={() => (cursor = 0)}
        onclick={() => choose(0)}
      >
        <span class="text-muted">＋</span>
        {#if query.trim()}
          <span class="truncate">Create <span class="font-semibold">{query.trim()}</span></span>
        {:else}
          <span class="text-muted">Type a name to create an empty initiative</span>
        {/if}
      </button>
    </li>

    <li
      class="flex items-center gap-2 px-3 pt-2 pb-1 text-[10px] tracking-wide text-muted uppercase"
    >
      <span>Your work</span>
      <span class="flex items-center gap-1 normal-case">
        {#each RELATIONS as name (name)}
          <button
            class={[
              "rounded px-1.5 py-px",
              relation === name ? "bg-accent/25 text-accent" : "text-muted hover:text-fg",
            ]}
            onclick={() => ((relation = name), (cursor = 0))}
          >
            {name}
          </button>
        {/each}
        <kbd class="ml-0.5 text-muted/70">Tab</kbd>
      </span>
      {#if loading}<span class="normal-case">· loading…</span>{/if}
    </li>

    {#each filtered as item, i (key(item))}
      <li>
        <button
          data-index={i + 1}
          class={[
            "flex w-full items-start gap-2.5 px-3 py-2 text-left",
            cursor === i + 1 ? "bg-accent/20" : "",
          ]}
          onmouseenter={() => (cursor = i + 1)}
          onclick={() => choose(i + 1)}
        >
          <span class="mt-0.5 shrink-0 rounded border border-border px-1 text-[10px] text-muted">
            {label(item.service)}
          </span>
          <span class="min-w-0 flex-1">
            <span class="block truncate text-[13px] text-fg">
              <span class="text-muted">{item.id}</span>
              {#each titleRuns(item) as run}<span
                  class={run.hit ? "font-semibold text-accent" : ""}>{run.text}</span
                >{/each}
            </span>
            <span class="block truncate text-[11px] text-muted">
              <span class={item.relation === "assigned" ? "text-fg/70" : ""}>{item.relation}</span>
              · {item.status ?? "no status"}{item.labels.length
                ? ` · ${item.labels.join(", ")}`
                : ""}
            </span>
          </span>
          <span class="mt-0.5 shrink-0 text-[11px]">
            {#if busy === key(item)}
              <span class="text-muted">importing…</span>
            {:else if item.imported}
              <span class="text-muted">open →</span>
            {:else}
              <span class="text-accent">start →</span>
            {/if}
          </span>
        </button>
      </li>
    {:else}
      {#if !loading}
        <li class="px-3 py-2 text-[13px] text-muted">
          {query ? "Nothing matches that search." : `Nothing ${relation === "all" ? "in your queue" : relation} right now.`}
        </li>
      {/if}
    {/each}

    {#each errors as err (err.service)}
      <li
        class={[
          "flex items-center gap-2 px-3 py-1.5 text-[11px]",
          err.kind === "auth" ? "text-fg/70" : "text-yellow-500/80",
        ]}
      >
        <span class="min-w-0 flex-1 truncate" title={err.reason}>
          {#if err.kind === "auth"}
            <span class="text-fg/90">{label(err.service)} needs reconnecting</span>
            <span class="text-muted">— your session expired</span>
          {:else}
            {label(err.service)} unavailable — {err.reason}
          {/if}
        </span>
        {#if err.kind === "auth"}
          <button
            class="shrink-0 rounded border border-accent/40 px-1.5 py-px text-accent hover:bg-accent/15 disabled:opacity-50"
            disabled={reconnecting !== null}
            onclick={() => reconnect(err.service)}
          >
            {reconnecting === err.service ? "waiting for browser…" : "Reconnect"}
          </button>
        {/if}
      </li>
    {/each}

    {#if reconnectError}
      <li class="px-3 py-1.5 text-[11px] text-red-300">{reconnectError}</li>
    {/if}
  </ul>

  <p class="border-t border-border px-3 py-2 text-[11px] text-muted">
    Enter to confirm · ↑↓ to move · Tab to filter · Esc to cancel
  </p>
</Overlay>

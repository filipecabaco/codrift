<script lang="ts">
  // Which agent an initiative launches, changed without touching the mouse.
  //
  // The choice already lived in a <select> in the Context view, which meant
  // leaving the keyboard, and it was invisible from the sidebar — where you
  // actually stand when you decide "this one should run on the work account".
  import Overlay from "$lib/Overlay.svelte";
  import { ADAPTERS, setDefaultAgent, setInitiativeAgent, type Initiative } from "$lib/api";
  import { workspace as ws } from "$lib/workspace.svelte";

  let {
    initiative,
    onDone,
    onClose,
  }: {
    initiative: Initiative;
    /** Applied — the caller reloads so the sidebar and Context view agree. */
    onDone: (choice: string, scope: Scope) => void;
    onClose: () => void;
  } = $props();

  // Same list, two questions. Setting the default while you are already looking
  // at the choices beats hunting for the same list again in Settings.
  type Scope = "initiative" | "default";
  let scope = $state<Scope>("initiative");

  type Choice = { name: string; kind: "adapter" | "profile"; detail: string };

  const choices = $derived<Choice[]>([
    ...ADAPTERS.map((a) => ({ name: a, kind: "adapter" as const, detail: "base adapter" })),
    ...ws.profiles.map((p) => ({
      name: p.name,
      kind: "profile" as const,
      detail: `profile · ${p.adapter ?? "claude"}`,
    })),
  ]);

  let query = $state("");
  let error = $state<string | null>(null);
  let busy = $state(false);
  let input: HTMLInputElement;
  let listEl = $state<HTMLElement | null>(null);

  const current = $derived(ws.agentChoiceFor(initiative));
  const filtered = $derived(
    choices.filter((c) => c.name.toLowerCase().includes(query.trim().toLowerCase())),
  );

  // Opens on what is already in force, so Enter is a confirmation rather than a
  // surprise. Positioned once at init: an effect would fight the query reset
  // below for the same variable.
  // svelte-ignore state_referenced_locally
  let cursor = $state(Math.max(0, choices.findIndex((c) => c.name === current)));

  $effect(() => {
    input?.focus();
  });

  // Guarded rather than a bare `query;` read: that form also fires on mount,
  // which would throw away the starting position above.
  let lastQuery = "";
  $effect(() => {
    if (query === lastQuery) return;
    lastQuery = query;
    cursor = 0;
  });

  $effect(() => {
    listEl?.querySelector<HTMLElement>(`[data-index="${cursor}"]`)?.scrollIntoView({ block: "nearest" });
  });

  async function apply(choice: Choice | undefined) {
    if (!choice || busy) return;
    busy = true;
    error = null;
    try {
      if (scope === "default") {
        await setDefaultAgent(choice.name);
        ws.defaultAgent = choice.name;
      } else {
        await setInitiativeAgent(initiative.id, choice.name);
      }
      onDone(choice.name, scope);
    } catch (e) {
      error = (e as Error).message;
      busy = false;
    }
  }

  function onkeydown(e: KeyboardEvent) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      cursor = Math.min(cursor + 1, filtered.length - 1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      cursor = Math.max(cursor - 1, 0);
    } else if (e.key === "Tab") {
      e.preventDefault();
      e.stopPropagation();
      scope = scope === "initiative" ? "default" : "initiative";
    } else if (e.key === "Enter") {
      e.preventDefault();
      apply(filtered[cursor]);
    }
  }
</script>

<Overlay label="Change agent" width="480px" top="12vh" padded={false} ownsTab {onClose}>
  <div class="border-b border-border px-3 pt-3 pb-2">
    <h3 class="text-[13px] font-semibold text-fg">
      Agent for <span class="text-accent">{initiative.name}</span>
    </h3>
    <div class="mt-2 flex items-center gap-1">
      {#each [{ id: "initiative", label: "This initiative" }, { id: "default", label: "New initiatives" }] as tab (tab.id)}
        <button
          class={[
            "rounded-md px-2 py-1 text-[11px]",
            scope === tab.id ? "bg-accent/20 text-white" : "text-muted hover:text-fg",
          ]}
          aria-pressed={scope === tab.id}
          onclick={() => (scope = tab.id as Scope)}
        >
          {tab.label}
        </button>
      {/each}
      <kbd class="text-[10px] text-muted/70">⇥</kbd>
    </div>
  </div>

  <div class="border-b border-border px-3 py-2">
    <input
      bind:this={input}
      bind:value={query}
      {onkeydown}
      aria-label="Filter agents"
      placeholder="Filter agents and profiles…"
      autocomplete="off"
      spellcheck="false"
      class="w-full rounded-md border border-border bg-canvas px-3 py-1.5 text-sm text-fg outline-none focus:border-accent"
    />
  </div>

  {#if error}
    <p class="border-b border-red-500/30 bg-red-500/10 px-3 py-2 text-[11px] text-red-300">{error}</p>
  {/if}

  <ul bind:this={listEl} class="max-h-72 overflow-y-auto py-1" role="listbox" aria-label="Agents">
    {#each filtered as choice, i (choice.name)}
      <li>
        <button
          data-index={i}
          role="option"
          aria-selected={i === cursor}
          class={[
            "flex w-full items-center gap-2 px-3 py-1.5 text-left text-[13px]",
            i === cursor ? "bg-accent/20 text-white" : "text-fg/90",
          ]}
          onmouseenter={() => (cursor = i)}
          onclick={() => apply(choice)}
        >
          <span class="min-w-0 flex-1 truncate">{choice.name}</span>
          <span class="shrink-0 text-[11px] text-muted">{choice.detail}</span>
          {#if scope === "initiative" ? choice.name === current : choice.name === ws.defaultAgent}
            <span class="shrink-0 text-[11px] text-accent">current</span>
          {/if}
        </button>
      </li>
    {:else}
      <li class="px-3 py-2 text-[13px] text-muted">Nothing matches “{query}”.</li>
    {/each}
  </ul>

  <p class="border-t border-border px-3 py-2 text-[11px] text-muted">
    {#if scope === "initiative"}
      Applies to agents you start next — running ones keep their own.
    {:else}
      Seeds every initiative that doesn't choose for itself.
    {/if}
    · ↑↓ move · ⇥ scope · Enter apply · Esc cancel
  </p>
</Overlay>

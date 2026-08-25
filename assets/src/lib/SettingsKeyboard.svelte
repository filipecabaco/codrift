<script lang="ts">
  // Read-only on purpose: the file is the editor. Rebinding lives in
  // ~/.codrift/keybindings.json because the TUI and the backend read the same
  // file, and a second source of truth in the UI would have to win or lose.
  import { ACTION_LABELS, formatSpec, type ActionId, type Keymap } from "$lib/keys";

  let { keymap }: { keymap: Keymap } = $props();

  let query = $state("");

  // Bound actions first, in the order the keymap defines them; unbound ones
  // (palette-only commands) follow, since there is no key to look up.
  const rows = $derived.by(() => {
    const q = query.trim().toLowerCase();
    return (Object.keys(ACTION_LABELS) as ActionId[])
      .map((id) => ({ id, label: ACTION_LABELS[id], spec: formatSpec(keymap[id]) }))
      .filter((r) => !q || `${r.label} ${r.id} ${r.spec}`.toLowerCase().includes(q))
      .sort((a, b) => Number(!a.spec) - Number(!b.spec));
  });
</script>

<div class="flex h-full min-h-0 flex-col">
  <div class="border-b border-border px-4 py-3">
    <h2 class="text-[13px] font-semibold text-fg">Keyboard</h2>
    <p class="text-[11px] text-muted">Every command, and the key it answers to right now.</p>
  </div>

  <div class="border-b border-border px-4 py-2">
    <input
      bind:value={query}
      aria-label="Filter shortcuts"
      placeholder="Search commands…"
      autocomplete="off"
      spellcheck="false"
      class="w-full rounded-md border border-border bg-canvas px-3 py-1.5 text-xs text-fg outline-none focus:border-accent"
    />
  </div>

  <ul class="min-h-0 flex-1 overflow-y-auto p-2">
    {#each rows as row (row.id)}
      <li class="flex items-center gap-3 rounded-md px-2 py-1.5 hover:bg-canvas/60">
        <span class="min-w-0 flex-1 truncate text-[12px] text-fg/90">{row.label}</span>
        <code class="shrink-0 text-[10px] text-muted/70">{row.id}</code>
        {#if row.spec}
          <kbd class="shrink-0 rounded border border-border bg-canvas px-1.5 py-px text-[10px] text-fg/80">
            {row.spec}
          </kbd>
        {:else}
          <span class="shrink-0 text-[10px] text-muted">palette only</span>
        {/if}
      </li>
    {:else}
      <li class="px-3 py-2 text-[13px] text-muted">Nothing matches “{query}”.</li>
    {/each}
  </ul>

  <p class="shrink-0 border-t border-border px-4 py-2 text-[11px] text-muted">
    Rebind in <code class="rounded bg-canvas px-1">~/.codrift/keybindings.json</code> — any action
    you leave out keeps its default. Restart to pick up changes.
  </p>
</div>

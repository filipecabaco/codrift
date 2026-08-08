<script lang="ts">
  import Overlay from "$lib/Overlay.svelte";
  import type { ActionId } from "$lib/keys";

  type Item = { id: ActionId; label: string; spec: string };
  let { items, onRun, onClose }: { items: Item[]; onRun: (id: ActionId) => void; onClose: () => void } =
    $props();

  let query = $state("");
  let cursor = $state(0);
  let input: HTMLInputElement;
  let listEl = $state<HTMLElement | null>(null);

  const filtered = $derived(
    items.filter((i) => i.label.toLowerCase().includes(query.toLowerCase())),
  );

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

  function onkeydown(e: KeyboardEvent) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      cursor = Math.min(cursor + 1, filtered.length - 1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      cursor = Math.max(cursor - 1, 0);
    } else if (e.key === "Enter") {
      e.preventDefault();
      const item = filtered[cursor];
      if (item) onRun(item.id);
    }
  }
</script>

<Overlay label="Command palette" width="520px" top="12vh" padded={false} {onClose}>
  <input
    bind:this={input}
    bind:value={query}
    {onkeydown}
    name="command"
    aria-label="Run a command"
    placeholder="Run a command…"
    class="w-full border-b border-border bg-canvas px-3 py-2.5 text-sm text-fg outline-none"
  />
  <ul bind:this={listEl} class="max-h-80 overflow-y-auto py-1" role="listbox" aria-label="Commands">
    {#each filtered as item, i (item.id)}
      <li>
        <button
          data-index={i}
          role="option"
          aria-selected={i === cursor}
          class={["flex w-full items-center justify-between px-3 py-1.5 text-left text-[13px]", i === cursor ? "bg-accent/20 text-white" : "text-fg/90"]}
          onmouseenter={() => (cursor = i)}
          onclick={() => onRun(item.id)}
        >
          <span>{item.label}</span>
          {#if item.spec}<kbd class="text-[11px] text-muted">{item.spec}</kbd>{/if}
        </button>
      </li>
    {:else}
      <li class="px-3 py-2 text-[13px] text-muted">No matching command.</li>
    {/each}
  </ul>
</Overlay>

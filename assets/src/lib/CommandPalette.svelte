<script lang="ts">
  import type { ActionId } from "$lib/keys";

  type Item = { id: ActionId; label: string; spec: string };
  let { items, onRun, onClose }: { items: Item[]; onRun: (id: ActionId) => void; onClose: () => void } =
    $props();

  let query = $state("");
  let cursor = $state(0);
  let input: HTMLInputElement;

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

  function onkeydown(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
    } else if (e.key === "ArrowDown") {
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

<div
  class="fixed inset-0 z-50 flex items-start justify-center bg-black/50 pt-[12vh]"
  onclick={onClose}
  role="presentation"
>
  <div
    class="w-[520px] max-w-[90vw] overflow-hidden rounded-lg border border-border bg-surface shadow-2xl"
    onclick={(e) => e.stopPropagation()}
    role="presentation"
  >
    <input
      bind:this={input}
      bind:value={query}
      {onkeydown}
      name="command"
      aria-label="Run a command"
      placeholder="Run a command…"
      class="w-full border-b border-border bg-canvas px-3 py-2.5 text-sm text-fg outline-none"
    />
    <ul class="max-h-80 overflow-y-auto py-1">
      {#each filtered as item, i (item.id)}
        <li>
          <button
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
  </div>
</div>

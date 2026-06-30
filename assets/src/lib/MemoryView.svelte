<script lang="ts">
  import { rpc, type MemoryEntry } from "$lib/api";

  let { initiativeId }: { initiativeId: string } = $props();

  let query = $state("");
  let entries = $state<MemoryEntry[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);

  const typeColor: Record<string, string> = {
    decision: "bg-purple-500/20 text-purple-300",
    summary: "bg-blue-500/20 text-blue-300",
    snippet: "bg-green-500/20 text-green-300",
    file_context: "bg-teal-500/20 text-teal-300",
    note: "bg-zinc-500/20 text-zinc-300",
  };

  async function run(q: string) {
    loading = true;
    error = null;
    try {
      const trimmed = q.trim();
      entries = trimmed
        ? await rpc<MemoryEntry[]>("memory_search", { initiative_id: initiativeId, query: trimmed })
        : await rpc<MemoryEntry[]>("memory_recent", { initiative_id: initiativeId, limit: 50 });
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    void initiativeId;
    query = "";
    run("");
  });

  let timer: ReturnType<typeof setTimeout>;
  function onInput() {
    clearTimeout(timer);
    timer = setTimeout(() => run(query), 250);
  }
</script>

<div class="flex h-full flex-col">
  <div class="border-b border-border px-4 py-2">
    <input
      bind:value={query}
      oninput={onInput}
      name="memory-search"
      aria-label="Search memory"
      placeholder={'Search memory…  (FTS5: words, "phrases", AND / OR / NOT)'}
      class="w-full rounded-md border border-border bg-canvas px-3 py-1.5 text-sm text-fg outline-none focus:border-accent"
    />
  </div>
  <div class="min-h-0 flex-1 space-y-2 overflow-auto p-4">
    {#if loading}
      <p class="text-xs text-muted">Loading…</p>
    {:else if error}
      <p class="text-xs text-red-400">{error}</p>
    {:else if entries.length === 0}
      <p class="text-xs text-muted">No memory entries{query ? " match that query." : " yet."}</p>
    {:else}
      {#each entries as e (e.id)}
        <div class="rounded-md border border-border bg-surface p-3">
          <div class="mb-1 flex items-center gap-2">
            <span
              class={[
                "rounded px-1.5 py-0.5 text-[10px] uppercase",
                typeColor[e.chunk_type] ?? "bg-zinc-500/20 text-zinc-300",
              ]}
            >
              {e.chunk_type}
            </span>
            <span class="text-[11px] text-muted">{e.source}</span>
            <span class="ml-auto text-[11px] text-muted">#{e.id}</span>
          </div>
          <pre class="whitespace-pre-wrap text-[13px] leading-5 text-fg/90">{e.content}</pre>
        </div>
      {/each}
    {/if}
  </div>
</div>

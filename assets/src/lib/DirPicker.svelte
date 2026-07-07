<script lang="ts">
  import { rpc } from "$lib/api";

  let {
    onSubmit,
    onClose,
  }: {
    onSubmit: (path: string) => void;
    onClose: () => void;
  } = $props();

  // Start browsing from home, matching the "start from ~" convention.
  let value = $state("~/");
  let base = $state("~");
  let entries = $state<string[]>([]);
  let cursor = $state(0);
  let input: HTMLInputElement;

  $effect(() => {
    input?.focus();
    // Put the caret at the end so typing continues the path.
    input?.setSelectionRange(value.length, value.length);
  });

  // The still-being-typed trailing segment, e.g. "Doc" in "~/Doc". Used to
  // fuzzy-filter the listed directory against what the user is typing.
  const fragment = $derived(value.slice(value.lastIndexOf("/") + 1));

  // Subsequence fuzzy match with light scoring: exact-prefix and contiguous
  // matches rank first, so "dl" finds "Downloads" but "Documents" (prefix)
  // still wins for "doc".
  function score(query: string, target: string): number | null {
    if (!query) return 0;
    const q = query.toLowerCase();
    const t = target.toLowerCase();
    if (t.startsWith(q)) return 1000 - target.length;
    let qi = 0;
    let last = -1;
    let bonus = 0;
    for (let ti = 0; ti < t.length && qi < q.length; ti++) {
      if (t[ti] === q[qi]) {
        if (ti === last + 1) bonus += 2;
        last = ti;
        qi++;
      }
    }
    return qi === q.length ? bonus - target.length : null;
  }

  const matches = $derived(
    entries
      .map((name) => ({ name, s: score(fragment, name) }))
      .filter((m): m is { name: string; s: number } => m.s !== null)
      .sort((a, b) => b.s - a.s)
      .map((m) => m.name),
  );

  // Reset the highlight whenever the candidate list changes.
  $effect(() => {
    matches;
    cursor = 0;
  });

  // Reload the listing whenever the directory portion of the input changes.
  // Debounced so fast typing doesn't hammer the backend.
  let listTimer: ReturnType<typeof setTimeout> | undefined;
  $effect(() => {
    const path = value;
    clearTimeout(listTimer);
    listTimer = setTimeout(async () => {
      try {
        const res = await rpc<{ base: string; entries: string[] }>("list_dirs", { path });
        base = res.base;
        entries = res.entries;
      } catch {
        entries = [];
      }
    }, 80);
  });

  function join(dir: string, name: string): string {
    return dir.endsWith("/") ? dir + name : dir + "/" + name;
  }

  // Complete into the highlighted directory and keep browsing (trailing slash
  // so the next listing is that directory's children).
  function complete() {
    const pick = matches[cursor];
    if (!pick) return;
    value = join(base, pick) + "/";
    queueMicrotask(() => input?.setSelectionRange(value.length, value.length));
  }

  function onkeydown(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      cursor = Math.min(cursor + 1, matches.length - 1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      cursor = Math.max(cursor - 1, 0);
    } else if (e.key === "Tab" || e.key === "ArrowRight") {
      // Tab always completes; ArrowRight only when the caret is at the end.
      if (e.key === "ArrowRight" && input.selectionStart !== value.length) return;
      e.preventDefault();
      complete();
    } else if (e.key === "Enter") {
      e.preventDefault();
      const v = value.trim();
      if (v) onSubmit(v);
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
    <div class="border-b border-border px-3 pt-3">
      <h3 class="mb-2 text-[13px] font-semibold text-fg">Add directory</h3>
      <input
        bind:this={input}
        bind:value
        {onkeydown}
        name="dir"
        aria-label="Directory path"
        placeholder="~/path/to/repo"
        autocomplete="off"
        spellcheck="false"
        class="w-full rounded-md border border-border bg-canvas px-3 py-2 font-mono text-sm text-fg outline-none focus:border-accent"
      />
    </div>
    <ul class="max-h-72 overflow-y-auto py-1">
      {#each matches as name, i (name)}
        <li>
          <button
            class={["flex w-full items-center gap-2 px-3 py-1.5 text-left text-[13px]", i === cursor ? "bg-accent/20 text-white" : "text-fg/90"]}
            onmouseenter={() => (cursor = i)}
            onclick={() => {
              cursor = i;
              complete();
              input?.focus();
            }}
          >
            <span class="text-muted">📁</span>
            <span class="truncate font-mono">{name}</span>
          </button>
        </li>
      {:else}
        <li class="px-3 py-2 text-[13px] text-muted">No matching directories.</li>
      {/each}
    </ul>
    <p class="border-t border-border px-3 py-2 text-[11px] text-muted">
      Tab to complete · ↑↓ to navigate · Enter to add · Esc to cancel
    </p>
  </div>
</div>

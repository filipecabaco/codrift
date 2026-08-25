<script lang="ts">
  // A path input that completes as you type: the field plus the list of
  // directories under whatever the field currently points at.
  //
  // Extracted from the "add directory" overlay because Settings needs the same
  // affordance for the default workspace folder — a plain text box for a
  // filesystem path is a typo waiting to be saved.
  import { rpc } from "$lib/api";

  let {
    value = $bindable(),
    onSubmit,
    placeholder = "~/path/to/repo",
    label = "Directory path",
    autofocus = false,
    listClass = "max-h-72",
  }: {
    value: string;
    /** Enter on a non-empty field. Omit when the caller only wants the value. */
    onSubmit?: (path: string) => void;
    placeholder?: string;
    label?: string;
    autofocus?: boolean;
    /** Height budget for the suggestion list — a panel has less room than an overlay. */
    listClass?: string;
  } = $props();

  let base = $state("~");
  let entries = $state<string[]>([]);
  let cursor = $state(0);
  let input = $state<HTMLInputElement | null>(null);

  export function focus() {
    input?.focus();
    // Caret at the end so typing continues the path rather than splitting it.
    input?.setSelectionRange(value.length, value.length);
  }

  $effect(() => {
    if (autofocus) focus();
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

  // `.git` is never a project directory — offering it invites adding a repo's
  // internals as a workspace.
  const HIDDEN = new Set([".git"]);

  const matches = $derived(
    entries
      .filter((name) => !HIDDEN.has(name))
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
    queueMicrotask(() => {
      input?.setSelectionRange(value.length, value.length);
      // Programmatic edits don't scroll the field, so a long path would still
      // show its middle — the completed segment has to be the visible one.
      if (input) input.scrollLeft = input.scrollWidth;
    });
  }

  function onkeydown(e: KeyboardEvent) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      cursor = Math.min(cursor + 1, matches.length - 1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      cursor = Math.max(cursor - 1, 0);
    } else if (e.key === "Tab" || e.key === "ArrowRight") {
      // Tab always completes; ArrowRight only when the caret is at the end.
      if (e.key === "ArrowRight" && input?.selectionStart !== value.length) return;
      if (!matches.length) return;
      e.preventDefault();
      e.stopPropagation();
      complete();
    } else if (e.key === "Enter") {
      e.preventDefault();
      const v = value.trim();
      if (v) onSubmit?.(v);
    }
  }
</script>

<input
  bind:this={input}
  bind:value
  {onkeydown}
  {placeholder}
  name="dir"
  aria-label={label}
  autocomplete="off"
  spellcheck="false"
  class="w-full rounded-md border border-border bg-canvas px-3 py-2 font-mono text-sm text-fg outline-none focus:border-accent"
/>

<ul class={["overflow-y-auto py-1", listClass]}>
  {#each matches as name, i (name)}
    <li>
      <button
        class={[
          "flex w-full items-center gap-2 px-3 py-1.5 text-left text-[13px]",
          i === cursor ? "bg-accent/20 text-white" : "text-fg/90",
        ]}
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
    <!-- About the filter, never about the path: a folder typed in full has no
         child matching its own name, and "no matching directories" there read
         as "that folder does not exist". -->
    <li class="px-3 py-2 text-[13px] text-muted">
      {fragment ? `No subfolder matches “${fragment}”.` : "No subfolders here."}
    </li>
  {/each}
</ul>

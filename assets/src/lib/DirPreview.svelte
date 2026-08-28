<script lang="ts">
  // What a directory *is*, shown the moment the sidebar cursor lands on it.
  //
  // Deliberately not the Tree pane: moving the cursor over a folder should never
  // hijack the pane you had open. This reads the README when there is one —
  // which is what a person actually wants to know about a repo — and falls back
  // to a shallow tree only when there isn't. Neither is browsable; for that
  // there is "3 Tree", one keypress away.
  import { Icon } from "@steeze-ui/svelte-icon";
  import { rpc, type DirPreview, type Initiative } from "$lib/api";
  import { dirIcon, FolderIcon } from "$lib/icons";
  import { markdownFor } from "$lib/markdown";

  let {
    initiativeId,
    dir,
    onOpenTree,
  }: {
    initiativeId: string;
    /** The dir entry as the initiative holds it — source path, plus its git isolation. */
    dir: Initiative["dirs"][number];
    onOpenTree: () => void;
  } = $props();

  let preview = $state<DirPreview | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);

  const base = (p: string) => p.split("/").filter(Boolean).pop() ?? p;
  const home = (p: string) => p.replace(/^\/(Users|home)\/[^/]+/, "~");

  // A workspace refresh rebuilds every dir entry, so depending on the `dir`
  // object itself would re-fetch the same README on each one. `$derived` only
  // notifies when the string actually changes, which is the real trigger:
  // the cursor moved to a different directory.
  const path = $derived(dir.path);

  $effect(() => {
    const dirPath = path;
    const id = initiativeId;
    let stale = false;
    loading = true;
    error = null;

    rpc<DirPreview>("dir_preview", { initiative_id: id, path: dirPath })
      .then((res) => {
        if (stale) return;
        preview = res;
        loading = false;
      })
      .catch((e: Error) => {
        if (stale) return;
        error = e.message;
        loading = false;
      });

    return () => {
      stale = true;
    };
  });

  // The content is a README from a directory the user chose to add — the same
  // trust boundary the initiative's own context files already sit behind
  // (ContextOverview renders those the same way), and the app runs no
  // cross-origin session for a script to steal.
  //
  // The parser is rebuilt per preview because its image resolution is relative
  // to `preview.dir` — the directory that was actually read, which for a
  // worktree-backed entry is the worktree rather than the source repo.
  const html = $derived(
    preview?.kind === "readme"
      ? (markdownFor(initiativeId, preview.dir).parse(preview.content) as string)
      : "",
  );
</script>

<div class="flex h-full flex-col">
  <header class="shrink-0 border-b border-border px-6 py-3">
    <div class="flex items-center gap-2">
      <Icon
        src={dirIcon(dir.git ?? false)}
        class="size-4 shrink-0 text-muted"
        title={dir.git ? "Git repository" : "Folder (not a git repository)"}
      />
      <h2 class="min-w-0 truncate text-[15px] font-semibold text-fg">{base(dir.path)}</h2>
      {#if dir.worktree_enabled}
        <span
          class="shrink-0 rounded border border-accent/40 px-1.5 text-[11px] text-accent"
          title={dir.worktree_path
            ? `Agents run in the worktree at ${home(dir.worktree_path)}`
            : "Isolated git worktree"}>worktree</span
        >
      {:else if dir.branch}
        <span class="shrink-0 rounded border border-accent/40 px-1.5 text-[11px] text-accent"
          >{dir.branch}</span
        >
      {/if}
      <button
        class="ml-auto shrink-0 rounded-md border border-border px-2 py-0.5 text-[11px] text-muted hover:text-fg"
        title="Browse every file in this initiative"
        onclick={onOpenTree}
      >
        Browse in Tree
      </button>
    </div>
    <p class="mt-0.5 truncate font-mono text-[11px] text-muted" title={dir.path}>
      {home(dir.path)}
    </p>
  </header>

  <div class="min-h-0 flex-1 overflow-auto px-6 py-4">
    {#if loading}
      <p class="text-xs text-muted">Reading…</p>
    {:else if error}
      <p class="text-xs text-red-400">{error}</p>
    {:else if preview?.kind === "readme"}
      <p class="mb-3 font-mono text-[11px] text-muted">{preview.name}</p>
      <div
        class="text-[13px] leading-6 [&_a]:text-accent [&_a]:underline [&_code]:rounded [&_code]:bg-surface [&_code]:px-1 [&_code]:py-0.5 [&_h1]:mt-0 [&_h1]:mb-3 [&_h1]:text-lg [&_h1]:font-semibold [&_h1]:text-fg [&_h2]:mt-5 [&_h2]:mb-2 [&_h2]:text-base [&_h2]:font-semibold [&_h2]:text-accent [&_h3]:mt-3 [&_h3]:mb-1 [&_h3]:font-semibold [&_img]:my-2 [&_img]:max-w-full [&_img]:rounded [&_img]:border [&_img]:border-border [&_li]:my-0.5 [&_p]:my-2 [&_pre]:my-2 [&_pre]:overflow-auto [&_pre]:rounded [&_pre]:bg-surface [&_pre]:p-3 [&_strong]:text-fg [&_table]:my-2 [&_table]:block [&_table]:overflow-x-auto [&_td]:border [&_td]:border-border [&_td]:px-2 [&_td]:py-1 [&_th]:border [&_th]:border-border [&_th]:px-2 [&_th]:py-1 [&_ul]:my-2 [&_ul]:list-disc [&_ul]:pl-5"
      >
        {@html html}
      </div>
    {:else if preview?.kind === "tree"}
      <p class="mb-2 text-[11px] text-muted">
        No README here — showing the top of the tree instead.
      </p>
      <ul class="list-none font-mono text-[12px]">
        {#each preview.entries as entry (entry.path)}
          <li
            class={["flex items-center gap-1.5 py-px", entry.dir ? "text-fg/90" : "text-fg/60"]}
            style="padding-left: {entry.depth * 14}px"
          >
            {#if entry.dir}
              <Icon src={FolderIcon} class="size-3 shrink-0 text-muted" />
            {:else}
              <span class="w-3 shrink-0"></span>
            {/if}
            <span class="truncate">{entry.name}{entry.dir ? "/" : ""}</span>
          </li>
        {/each}
      </ul>
      {#if preview.truncated}
        <p class="mt-2 text-[11px] text-muted">
          …and more. <button class="text-accent underline" onclick={onOpenTree}>
            Browse in Tree
          </button> for the rest.
        </p>
      {/if}
    {:else}
      <p class="text-xs text-muted">This directory is empty.</p>
    {/if}
  </div>
</div>

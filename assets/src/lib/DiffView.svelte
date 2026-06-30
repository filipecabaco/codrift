<script lang="ts">
  import { rpc, type DiffFile } from "$lib/api";
  import { highlightLines, langForPath, type ThemedToken } from "$lib/highlight";

  let { initiativeId }: { initiativeId: string } = $props();

  type Row =
    | { kind: "hunk"; header: string }
    | { kind: "line"; type: string; tokens: ThemedToken[] };
  type ViewFile = { path: string; additions: number; deletions: number; rows: Row[] };

  let viewFiles = $state<ViewFile[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);

  const lineBg: Record<string, string> = { add: "bg-green-500/15", remove: "bg-red-500/15" };
  const sign: Record<string, string> = { add: "+", remove: "-" };

  async function buildFile(file: DiffFile): Promise<ViewFile> {
    const contents = file.hunks.flatMap((h) => h.lines.map((l) => l.content));
    const tokens = await highlightLines(contents, langForPath(file.path));
    const rows: Row[] = [];
    let i = 0;
    for (const hunk of file.hunks) {
      rows.push({ kind: "hunk", header: hunk.header });
      for (const line of hunk.lines) {
        rows.push({
          kind: "line",
          type: line.type,
          tokens: tokens[i] ?? [{ content: line.content, color: "var(--color-fg)" } as ThemedToken],
        });
        i++;
      }
    }
    return { path: file.path, additions: file.additions, deletions: file.deletions, rows };
  }

  $effect(() => {
    const id = initiativeId;
    loading = true;
    error = null;
    viewFiles = [];
    rpc<DiffFile[]>("get_diff", { initiative_id: id })
      .then(async (files) => {
        viewFiles = await Promise.all(files.map(buildFile));
      })
      .catch((e) => (error = (e as Error).message))
      .finally(() => (loading = false));
  });
</script>

<div class="h-full overflow-y-auto p-4 text-[13px] leading-5">
  {#if loading}
    <p class="text-muted">Loading diff…</p>
  {:else if error}
    <p class="text-red-400">{error}</p>
  {:else if viewFiles.length === 0}
    <p class="text-muted">No changes.</p>
  {:else}
    {#each viewFiles as file (file.path)}
      <div class="mb-4 overflow-hidden rounded-md border border-border">
        <div class="flex items-center justify-between border-b border-border bg-surface px-3 py-1.5">
          <span class="text-accent">{file.path}</span>
          <span class="text-muted">
            <span class="text-green-400">+{file.additions}</span>
            <span class="text-red-400">-{file.deletions}</span>
          </span>
        </div>
        {#each file.rows as row}
          {#if row.kind === "hunk"}
            <div class="bg-accent/10 px-3 py-0.5 text-[11px] text-accent">{row.header}</div>
          {:else}
            <div class={["flex whitespace-pre", lineBg[row.type] ?? ""]}>
              <span class="w-4 shrink-0 select-none text-center text-muted">{sign[row.type] ?? " "}</span>
              <span class="flex-1 overflow-x-auto px-3"
                >{#each row.tokens as t}<span style="color:{t.color ?? 'var(--color-fg)'}">{t.content}</span>{/each}</span
              >
            </div>
          {/if}
        {/each}
      </div>
    {/each}
  {/if}
</div>

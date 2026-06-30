<script lang="ts">
  import { rpc } from "$lib/api";
  import { highlightToHtml, langForPath } from "$lib/highlight";

  let {
    initiativeId,
    selectedPath = $bindable<string | null>(null),
    onEdit,
  }: {
    initiativeId: string;
    selectedPath?: string | null;
    onEdit: (path: string) => void;
  } = $props();

  type Node = {
    name: string;
    key: string;
    fullPath: string;
    isFile: boolean;
    children: Node[];
  };

  let roots = $state<Node[]>([]);
  let expanded = $state<Set<string>>(new Set());
  let loading = $state(true);
  let error = $state<string | null>(null);
  let selected = $state<string | null>(null);
  let previewHtml = $state<string>("");
  let previewError = $state<string | null>(null);

  const base = (dir: string) => dir.split("/").filter(Boolean).pop() ?? dir;

  function buildTree(dir: string, files: string[]): Node {
    const root: Node = { name: base(dir), key: dir, fullPath: dir, isFile: false, children: [] };
    for (const rel of files) {
      const segs = rel.split("/");
      let node = root;
      let path = dir;
      segs.forEach((seg, i) => {
        path = `${path}/${seg}`;
        const isFile = i === segs.length - 1;
        let child = node.children.find((c) => c.name === seg);
        if (!child) {
          child = { name: seg, key: path, fullPath: path, isFile, children: [] };
          node.children.push(child);
        }
        node = child;
      });
    }
    sortNode(root);
    return root;
  }

  function sortNode(n: Node) {
    n.children.sort((a, b) =>
      a.isFile === b.isFile ? a.name.localeCompare(b.name) : a.isFile ? 1 : -1,
    );
    n.children.forEach(sortNode);
  }

  function visibleRows(): { node: Node; depth: number }[] {
    const out: { node: Node; depth: number }[] = [];
    const walk = (n: Node, depth: number) => {
      out.push({ node: n, depth });
      if (!n.isFile && expanded.has(n.key)) n.children.forEach((c) => walk(c, depth + 1));
    };
    roots.forEach((r) => walk(r, 0));
    return out;
  }

  function toggle(node: Node) {
    if (node.isFile) {
      openFile(node);
      return;
    }
    const next = new Set(expanded);
    next.has(node.key) ? next.delete(node.key) : next.add(node.key);
    expanded = next;
  }

  async function openFile(node: Node) {
    selected = node.key;
    selectedPath = node.fullPath;
    previewError = null;
    previewHtml = "";
    try {
      const res = await rpc<{ content: string }>("read_file", {
        initiative_id: initiativeId,
        path: node.fullPath,
      });
      previewHtml = await highlightToHtml(res.content, langForPath(node.fullPath));
    } catch (e) {
      previewError = (e as Error).message;
    }
  }

  $effect(() => {
    const id = initiativeId;
    loading = true;
    error = null;
    selected = null;
    selectedPath = null;
    previewHtml = "";
    rpc<{ dirs: { dir: string; files: string[] }[] }>("list_tree", { initiative_id: id })
      .then((res) => {
        roots = res.dirs.map((d) => buildTree(d.dir, d.files));
        expanded = new Set(roots.map((r) => r.key)); // expand top-level dirs
      })
      .catch((e) => (error = (e as Error).message))
      .finally(() => (loading = false));
  });
</script>

<div class="flex h-full">
  <div class="w-1/2 max-w-md overflow-y-auto border-r border-border p-2 text-[13px]">
    {#if loading}
      <p class="text-muted">Loading tree…</p>
    {:else if error}
      <p class="text-red-400">{error}</p>
    {:else if roots.length === 0}
      <p class="text-muted">No files to show.</p>
    {:else}
      {#each visibleRows() as { node, depth } (node.key)}
        <button
          class={[
            "flex w-full items-center gap-1 rounded py-0.5 text-left hover:bg-surface",
            selected === node.key ? "bg-accent/20 text-white" : "text-fg/90",
          ]}
          style="padding-left: {depth * 14 + 4}px"
          onclick={() => toggle(node)}
        >
          {#if node.isFile}
            <span class="text-muted">·</span>{node.name}
          {:else}
            <span class="text-muted">{expanded.has(node.key) ? "▾" : "▸"}</span>
            <span class="font-semibold">{node.name}</span>
          {/if}
        </button>
      {/each}
    {/if}
  </div>

  <div class="flex min-w-0 flex-1 flex-col overflow-hidden">
    {#if selected}
      <div class="flex items-center justify-between border-b border-border px-3 py-1.5 text-[12px]">
        <span class="truncate text-muted">{selected.split("/").pop()}</span>
        <button class="shrink-0 text-accent hover:underline" onclick={() => onEdit(selected!)}>Edit</button>
      </div>
    {/if}
    <div class="min-h-0 flex-1 overflow-auto p-3 text-[12px] leading-5">
      {#if previewError}
        <p class="text-red-400">{previewError}</p>
      {:else if selected}
        <div class="[&_pre]:m-0 [&_pre]:p-0">{@html previewHtml}</div>
      {:else}
        <p class="text-muted">Select a file to preview.</p>
      {/if}
    </div>
  </div>
</div>

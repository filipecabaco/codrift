<script lang="ts">
  import { untrack } from "svelte";
  import { rpc } from "$lib/api";
  import { highlightToHtml, langForPath } from "$lib/highlight";
  import { themeState } from "$lib/theme.svelte";

  let {
    initiativeId,
    selectedPath = $bindable<string | null>(null),
    onEdit,
    onContextMenu,
    onLeave,
    revision = 0,
  }: {
    initiativeId: string;
    selectedPath?: string | null;
    onEdit: (path: string) => void;
    /** Right-click on a row. `isFile` decides which commands make sense. */
    onContextMenu?: (event: MouseEvent, path: string, isFile: boolean) => void;
    /** Called on Escape with no active filter. */
    onLeave?: () => void;
    /** Bumped by the editor on save; re-reads the previewed file when it changes. */
    revision?: number;
  } = $props();

  type Node = {
    name: string;
    key: string;
    fullPath: string;
    isFile: boolean;
    children: Node[];
  };

  type Row = {
    key: string;
    node: Node;
    depth: number;
    /** Filter results only: full path, shown instead of the bare name. */
    label?: string;
  };

  let roots = $state<Node[]>([]);
  let expanded = $state<Set<string>>(new Set());
  let loading = $state(true);
  let error = $state<string | null>(null);
  let selected = $state<string | null>(null);
  let previewHtml = $state<string>("");
  let previewError = $state<string | null>(null);
  let query = $state("");
  let cursor = $state(0);
  let paneEl = $state<HTMLElement | null>(null);
  let filterEl = $state<HTMLInputElement | null>(null);

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

  /** Subsequence score; consecutive and segment-start hits rank higher. Null = no match. */
  function fuzzyScore(q: string, s: string): number | null {
    const hay = s.toLowerCase();
    let at = 0;
    let score = 0;
    let prev = -2;
    for (const ch of q.toLowerCase()) {
      const idx = hay.indexOf(ch, at);
      if (idx === -1) return null;
      if (idx === prev + 1) score += 4;
      if (idx === 0 || "/._- ".includes(hay[idx - 1])) score += 3;
      score += 1;
      prev = idx;
      at = idx + 1;
    }
    return score - hay.length * 0.02;
  }

  /** Every file, flattened, for filtering. */
  const files = $derived.by(() => {
    const out: { node: Node; label: string }[] = [];
    const walk = (n: Node, prefix: string) => {
      for (const c of n.children) {
        const label = prefix ? `${prefix}/${c.name}` : c.name;
        if (c.isFile) out.push({ node: c, label });
        else walk(c, label);
      }
    };
    roots.forEach((r) => walk(r, r.name));
    return out;
  });

  const MAX_RESULTS = 200;

  const rows = $derived.by((): Row[] => {
    const q = query.trim();
    if (q) {
      return files
        .map((f) => ({ f, score: fuzzyScore(q, f.label) }))
        .filter((r): r is { f: (typeof files)[number]; score: number } => r.score !== null)
        .sort((a, b) => b.score - a.score)
        .slice(0, MAX_RESULTS)
        .map(({ f }) => ({ key: f.node.key, node: f.node, depth: 0, label: f.label }));
    }
    const out: Row[] = [];
    const walk = (n: Node, depth: number) => {
      out.push({ key: n.key, node: n, depth });
      if (!n.isFile && expanded.has(n.key)) n.children.forEach((c) => walk(c, depth + 1));
    };
    roots.forEach((r) => walk(r, 0));
    return out;
  });

  let seenQuery = "";
  $effect(() => {
    if (query !== seenQuery) {
      const wasFiltering = seenQuery !== "";
      seenQuery = query;
      const landing = !query && wasFiltering ? rows.findIndex((r) => r.key === selected) : -1;
      cursor = landing === -1 ? 0 : landing;
      scrollCursorIntoView();
    } else if (cursor > rows.length - 1) {
      cursor = Math.max(0, rows.length - 1);
    }
  });

  function moveCursor(delta: number) {
    if (rows.length === 0) return;
    cursor = Math.min(rows.length - 1, Math.max(0, cursor + delta));
    scrollCursorIntoView();
  }

  function scrollCursorIntoView() {
    requestAnimationFrame(() => {
      paneEl?.querySelector<HTMLElement>("[data-cursor]")?.scrollIntoView({ block: "nearest" });
    });
  }

  function toggle(node: Node) {
    if (node.isFile) {
      void openFile(node);
      return;
    }
    const next = new Set(expanded);
    next.has(node.key) ? next.delete(node.key) : next.add(node.key);
    expanded = next;
  }

  /** Expands the path to `node` so clearing the filter keeps it visible. */
  function revealInTree(node: Node) {
    const next = new Set(expanded);
    for (const root of roots) {
      if (!node.fullPath.startsWith(`${root.fullPath}/`)) continue;
      const rel = node.fullPath.slice(root.fullPath.length + 1).split("/");
      let path = root.fullPath;
      next.add(path);
      for (const seg of rel.slice(0, -1)) {
        path = `${path}/${seg}`;
        next.add(path);
      }
    }
    expanded = next;
  }

  function activate(row: Row) {
    if (row.label && row.node.isFile) revealInTree(row.node);
    toggle(row.node);
  }

  function expandRow(row: Row) {
    if (row.node.isFile || expanded.has(row.key)) {
      moveCursor(1);
      return;
    }
    expanded = new Set(expanded).add(row.key);
  }

  function collapseRow(row: Row) {
    if (!row.node.isFile && expanded.has(row.key)) {
      const next = new Set(expanded);
      next.delete(row.key);
      expanded = next;
      return;
    }
    for (let i = cursor - 1; i >= 0; i--) {
      if (rows[i].depth < row.depth) {
        cursor = i;
        scrollCursorIntoView();
        return;
      }
    }
  }

  function onPaneKeydown(e: KeyboardEvent) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const row = rows[cursor];
    const inFilter = e.target === filterEl;

    switch (e.key) {
      case "ArrowDown":
        moveCursor(1);
        break;
      case "ArrowUp":
        moveCursor(-1);
        break;
      case "j":
        if (inFilter) return;
        moveCursor(1);
        break;
      case "k":
        if (inFilter) return;
        moveCursor(-1);
        break;
      case "Home":
        cursor = 0;
        scrollCursorIntoView();
        break;
      case "End":
        cursor = Math.max(0, rows.length - 1);
        scrollCursorIntoView();
        break;
      case "ArrowRight":
        if (inFilter) return;
        if (row) expandRow(row);
        break;
      case "ArrowLeft":
        if (inFilter) return;
        if (row) collapseRow(row);
        break;
      case "Enter":
        if (row) activate(row);
        if (inFilter && row?.node.isFile) paneEl?.focus();
        break;
      case "e":
        if (inFilter) return;
        if (row?.node.isFile) onEdit(row.node.fullPath);
        break;
      case "/":
        if (inFilter) return;
        filterEl?.focus();
        filterEl?.select();
        break;
      // With the filter focused the app-level ⇥ handler stands aside (it is a
      // text field), so the tree answers for it and Tab leaves either way.
      case "Tab":
        onLeave?.();
        break;
      case "Escape":
        if (query) {
          query = "";
          paneEl?.focus();
        } else if (inFilter) {
          paneEl?.focus();
        } else {
          onLeave?.();
        }
        break;
      default:
        return;
    }
    // Bare keys are global actions; stop the ones the tree consumed.
    e.preventDefault();
    e.stopPropagation();
  }

  async function openFile(node: Node) {
    selected = node.key;
    selectedPath = node.fullPath;
    previewHtml = "";
    await loadPreview(node.fullPath);
  }

  async function loadPreview(path: string) {
    previewError = null;
    try {
      const res = await rpc<{ content: string }>("read_file", {
        initiative_id: initiativeId,
        path,
      });
      previewHtml = await highlightToHtml(res.content, langForPath(path));
    } catch (e) {
      previewError = (e as Error).message;
    }
  }

  // The editor writes the same file this pane is previewing, so a save has to
  // invalidate the preview — otherwise closing the editor shows the old text.
  // A theme change invalidates it too: the highlighted HTML has the old
  // theme's colours baked in.
  let seenRevision = 0;
  let seenTheme = themeState.id;
  $effect(() => {
    const r = revision;
    const theme = themeState.id;
    if (r === seenRevision && theme === seenTheme) return;
    seenRevision = r;
    seenTheme = theme;
    const path = untrack(() => selectedPath);
    if (path) void loadPreview(path);
  });

  $effect(() => {
    const id = initiativeId;
    loading = true;
    error = null;
    selected = null;
    selectedPath = null;
    previewHtml = "";
    query = "";
    cursor = 0;
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
  <!-- svelte-ignore a11y_no_noninteractive_element_to_interactive_role -->
  <div
    bind:this={paneEl}
    data-tree-pane
    role="tree"
    aria-label="Files"
    tabindex="0"
    onkeydown={onPaneKeydown}
    class="flex w-1/2 max-w-md flex-col border-r border-border text-[13px] outline-none focus-within:border-accent/50"
  >
    <div class="flex items-center gap-2 border-b border-border px-2 py-1.5">
      <span class="text-[11px] text-muted">/</span>
      <input
        bind:this={filterEl}
        bind:value={query}
        placeholder="Filter files…"
        aria-label="Filter files"
        spellcheck="false"
        autocomplete="off"
        class="min-w-0 flex-1 bg-transparent text-[12px] text-fg outline-none placeholder:text-muted"
      />
      {#if query}
        <span class="shrink-0 text-[11px] text-muted">
          {rows.length}{rows.length === MAX_RESULTS ? "+" : ""}
        </span>
      {/if}
    </div>

    <div class="min-h-0 flex-1 overflow-y-auto p-2">
      {#if loading}
        <p class="text-muted">Loading tree…</p>
      {:else if error}
        <p class="text-red-400">{error}</p>
      {:else if roots.length === 0}
        <p class="text-muted">No files to show.</p>
      {:else if rows.length === 0}
        <p class="text-muted">No file matches “{query}”.</p>
      {:else}
        {#each rows as row, i (row.key)}
          <button
            data-cursor={i === cursor ? "" : undefined}
            role="treeitem"
            aria-selected={selected === row.key}
            tabindex="-1"
            class={[
              "flex w-full items-center gap-1 rounded py-0.5 text-left hover:bg-surface",
              selected === row.key ? "bg-accent/20 text-white" : "text-fg/90",
              i === cursor ? "ring-1 ring-inset ring-accent/60" : "",
            ]}
            style="padding-left: {row.depth * 14 + 4}px"
            onclick={() => {
              cursor = i;
              activate(row);
            }}
            oncontextmenu={(e) => {
              cursor = i;
              activate(row);
              onContextMenu?.(e, row.node.fullPath, row.node.isFile);
            }}
          >
            {#if row.label}
              {@const cut = row.label.lastIndexOf("/")}
              <span class="text-muted">·</span>
              <span class="truncate">
                {#if cut > -1}<span class="text-muted">{row.label.slice(0, cut + 1)}</span>{/if}{row.label.slice(cut + 1)}
              </span>
            {:else if row.node.isFile}
              <span class="text-muted">·</span>{row.node.name}
            {:else}
              <span class="text-muted">{expanded.has(row.key) ? "▾" : "▸"}</span>
              <span class="font-semibold">{row.node.name}</span>
            {/if}
          </button>
        {/each}
      {/if}
    </div>
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

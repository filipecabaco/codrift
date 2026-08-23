<script lang="ts" module>
  export type MenuEntry =
    | {
        kind?: "item";
        label: string;
        /** Right-aligned shortcut or state, e.g. "⌘T" or "on". */
        hint?: string;
        disabled?: boolean;
        /** Destructive actions are coloured and pushed to the bottom of a group. */
        danger?: boolean;
        run: () => void;
      }
    | { kind: "separator" };

  /** Where a menu was summoned, and what it should offer there. */
  export type MenuRequest = { x: number; y: number; label: string; entries: MenuEntry[] };

  const isItem = (e: MenuEntry): e is Extract<MenuEntry, { run: () => void }> =>
    e.kind !== "separator";
</script>

<script lang="ts">
  // Right-click menus for the sidebar and the panes.
  //
  // Deliberately *not* built on Overlay: this has no scrim and no focus trap,
  // because a context menu that dims the window reads as a modal dialog, and the
  // thing it was opened on has to stay visible to make sense of the commands.
  let { request, onClose }: { request: MenuRequest; onClose: () => void } = $props();

  const MENU_WIDTH = 232;
  // Roughly one row; enough to keep the last item off the window edge.
  const EDGE_GUTTER = 8;

  let panel = $state<HTMLElement | null>(null);
  let cursor = $state(0);

  const items = $derived(request.entries.filter(isItem));

  // Measured after the first paint; until then the menu draws straight under the
  // pointer, which is where it belongs everywhere except the window's edges.
  let size = $state({ width: MENU_WIDTH, height: 0 });

  $effect(() => {
    if (panel) size = { width: panel.offsetWidth, height: panel.offsetHeight };
  });

  // Flip rather than clamp: a menu pinned by its top-left corner would cover the
  // very row it belongs to when opened near the bottom of the window.
  function flip(at: number, extent: number, limit: number): number {
    return at + extent + EDGE_GUTTER > limit ? Math.max(EDGE_GUTTER, at - extent) : at;
  }

  const placement = $derived({
    left: flip(request.x, size.width, window.innerWidth),
    top: flip(request.y, size.height, window.innerHeight),
  });

  $effect(() => {
    // Focus the panel itself, not the first item: the menu opens with nothing
    // selected so a stray Enter cannot fire a command the user never picked.
    panel?.focus();
  });

  function choose(entry: Extract<MenuEntry, { run: () => void }>) {
    if (entry.disabled) return;
    onClose();
    entry.run();
  }

  function move(delta: number) {
    const enabled = items.map((e, i) => (e.disabled ? -1 : i)).filter((i) => i >= 0);
    if (!enabled.length) return;
    const at = enabled.indexOf(cursor);
    cursor = enabled[(at + delta + enabled.length) % enabled.length] ?? enabled[0];
  }

  function onKeydown(e: KeyboardEvent) {
    switch (e.key) {
      case "Escape":
        e.preventDefault();
        e.stopPropagation();
        onClose();
        break;
      case "ArrowDown":
        e.preventDefault();
        move(1);
        break;
      case "ArrowUp":
        e.preventDefault();
        move(-1);
        break;
      case "Enter":
        e.preventDefault();
        if (items[cursor]) choose(items[cursor]);
        break;
    }
  }
</script>

<!-- A transparent full-window catcher, so the next click anywhere dismisses the
     menu without that click also landing on whatever was underneath. -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="fixed inset-0 z-50"
  onpointerdown={onClose}
  oncontextmenu={(e) => {
    e.preventDefault();
    onClose();
  }}
  onwheel={onClose}
></div>

<!-- svelte-ignore a11y_no_noninteractive_element_to_interactive_role -->
<ul
  bind:this={panel}
  class="fixed z-50 min-w-[232px] overflow-hidden rounded-md border border-border bg-surface py-1 text-xs shadow-2xl"
  style="left: {placement.left}px; top: {placement.top}px"
  role="menu"
  aria-label={request.label}
  tabindex="-1"
  onkeydown={onKeydown}
>
  {#each request.entries as entry, i (i)}
    {#if entry.kind === "separator"}
      <li role="separator" class="my-1 border-t border-border"></li>
    {:else}
      {@const index = items.indexOf(entry)}
      <li role="none">
        <button
          role="menuitem"
          class={[
            "flex w-full items-center gap-3 px-3 py-1.5 text-left",
            entry.disabled
              ? "cursor-default text-muted/50"
              : entry.danger
                ? "text-red-300 hover:bg-red-500/15"
                : "text-fg/90 hover:bg-accent/20 hover:text-white",
            !entry.disabled && cursor === index && "bg-accent/20 text-white",
          ]}
          disabled={entry.disabled}
          onmouseenter={() => (cursor = index)}
          onclick={() => choose(entry)}
        >
          <span class="min-w-0 flex-1 truncate">{entry.label}</span>
          {#if entry.hint}
            <span class="shrink-0 text-[10px] text-muted">{entry.hint}</span>
          {/if}
        </button>
      </li>
    {/if}
  {/each}
</ul>

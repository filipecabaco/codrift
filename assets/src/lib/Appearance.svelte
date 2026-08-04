<script lang="ts">
  // Theme and typeface in one place, both previewed live: arrowing through the
  // lists re-skins and re-typesets the whole app immediately, and Esc puts back
  // what you started with. You cannot judge a theme from a swatch or a font
  // from its name — you judge them by looking at your own work in them.
  import { onMount } from "svelte";
  import Overlay from "$lib/Overlay.svelte";
  import { applyTheme, selectTheme, themeState, type ThemeEntry } from "$lib/theme.svelte";
  import {
    MAX_SIZE,
    MIN_SIZE,
    applyFont,
    clampSize,
    fontState,
    optionByLabel,
    selectFont,
    type FontOption,
  } from "$lib/fonts.svelte";

  let { onClose }: { onClose: () => void } = $props();

  type Section = "theme" | "font";
  let section = $state<Section>("theme");

  const startedWith = {
    theme: themeState.id,
    font: fontState.label,
    size: fontState.size,
  };

  let query = $state("");
  let cursor = $state(0);
  let input: HTMLInputElement;
  let listEl = $state<HTMLElement | null>(null);
  let failed = $state<string | null>(null);

  const themes = $derived.by<ThemeEntry[]>(() => {
    const q = query.trim().toLowerCase();
    const list = themeState.available;
    return q ? list.filter((t) => `${t.label} ${t.id}`.toLowerCase().includes(q)) : list;
  });

  const fonts = $derived.by<FontOption[]>(() => {
    const q = query.trim().toLowerCase();
    const list = fontState.available;
    return q ? list.filter((f) => f.label.toLowerCase().includes(q)) : list;
  });

  const rows = $derived<(ThemeEntry | FontOption)[]>(section === "theme" ? themes : fonts);
  const rowLabel = (row: ThemeEntry | FontOption) => row.label;
  const isCurrent = (row: ThemeEntry | FontOption) =>
    section === "theme"
      ? (row as ThemeEntry).id === themeState.id
      : (row as FontOption).label === fontState.label;

  // Preview whatever the cursor lands on. Fire-and-forget: the last one wins,
  // so holding ↓ never queues a backlog of half-applied themes.
  let previewing: string | null = null;
  $effect(() => {
    const row = rows[cursor];
    if (!row) return;
    const key = `${section}:${rowLabel(row)}`;
    if (key === previewing) return;
    previewing = key;
    failed = null;
    if (section === "theme") {
      applyTheme((row as ThemeEntry).id).catch((e) => (failed = (e as Error).message));
    } else {
      applyFont(row as FontOption, fontState.size);
    }
  });

  $effect(() => {
    rows;
    section;
    cursor = 0;
  });

  $effect(() => {
    listEl?.querySelector<HTMLElement>(`[data-index="${cursor}"]`)?.scrollIntoView({ block: "nearest" });
  });

  function switchTo(next: Section) {
    section = next;
    query = "";
    previewing = null;
    cursor = Math.max(
      0,
      next === "theme"
        ? themeState.available.findIndex((t) => t.id === themeState.id)
        : fontState.available.findIndex((f) => f.label === fontState.label),
    );
    input?.focus();
  }

  function resize(delta: number) {
    applyFont(optionByLabel(fontState.label) ?? fontState.available[0], fontState.size + delta);
  }

  function keep() {
    const row = rows[cursor];
    if (section === "theme") {
      if (row) void selectTheme((row as ThemeEntry).id);
      // The font may have been resized while this panel was open.
      if (fontState.size !== startedWith.size)
        void selectFont(optionByLabel(fontState.label) ?? fontState.available[0], fontState.size);
    } else if (row) {
      void selectFont(row as FontOption, fontState.size);
    }
    onClose();
  }

  function revert() {
    if (themeState.id !== startedWith.theme) void applyTheme(startedWith.theme);
    if (fontState.label !== startedWith.font || fontState.size !== startedWith.size) {
      applyFont(optionByLabel(startedWith.font) ?? fontState.available[0], startedWith.size);
    }
    onClose();
  }

  function onkeydown(e: KeyboardEvent) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      cursor = Math.min(cursor + 1, rows.length - 1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      cursor = Math.max(cursor - 1, 0);
    } else if (e.key === "Tab") {
      e.preventDefault();
      e.stopPropagation();
      switchTo(section === "theme" ? "font" : "theme");
    } else if (e.key === "Enter") {
      e.preventDefault();
      keep();
    } else if (section === "font" && (e.key === "+" || e.key === "=" || e.key === "-")) {
      e.preventDefault();
      resize(e.key === "-" ? -1 : 1);
    }
  }

  onMount(() => {
    input?.focus();
    switchTo("theme");
  });
</script>

<Overlay label="Appearance" width="560px" top="10vh" padded={false} onClose={revert}>
  <div class="border-b border-border px-3 pt-3">
    <div class="mb-2 flex items-center gap-1">
      {#each [{ id: "theme", label: "Theme" }, { id: "font", label: "Font" }] as tab (tab.id)}
        <button
          class={[
            "rounded-md px-2 py-1 text-xs",
            section === tab.id ? "bg-accent/20 text-white" : "text-muted hover:text-fg",
          ]}
          aria-pressed={section === tab.id}
          onclick={() => switchTo(tab.id as Section)}
        >
          {tab.label}
        </button>
      {/each}
      <span class="ml-auto text-[11px] text-muted">
        {#if section === "theme"}
          {themeState.available.length} themes · VS Code format
        {:else}
          {fontState.available.length} installed · {fontState.size}px
        {/if}
      </span>
    </div>
    <input
      bind:this={input}
      bind:value={query}
      {onkeydown}
      aria-label={section === "theme" ? "Filter themes" : "Filter fonts"}
      placeholder={section === "theme" ? "Search themes…" : "Search fonts…"}
      autocomplete="off"
      spellcheck="false"
      class="w-full rounded-md border border-border bg-canvas px-3 py-2 text-sm text-fg outline-none focus:border-accent"
    />
  </div>

  {#if section === "font"}
    <div class="flex items-center gap-3 border-b border-border px-3 py-2 text-[12px] text-muted">
      <span>Size</span>
      <button
        class="rounded border border-border px-2 py-0.5 text-fg hover:border-accent disabled:opacity-40"
        disabled={fontState.size <= MIN_SIZE}
        onclick={() => resize(-1)}
        aria-label="Decrease font size">−</button
      >
      <span class="w-10 text-center text-fg">{fontState.size}px</span>
      <button
        class="rounded border border-border px-2 py-0.5 text-fg hover:border-accent disabled:opacity-40"
        disabled={fontState.size >= MAX_SIZE}
        onclick={() => resize(1)}
        aria-label="Increase font size">+</button
      >
      <span class="text-[11px]">terminal and editor</span>
    </div>
  {/if}

  <ul bind:this={listEl} class="max-h-[46vh] overflow-y-auto py-1" role="listbox" aria-label={section}>
    {#each rows as row, i (rowLabel(row))}
      <li>
        <button
          data-index={i}
          role="option"
          aria-selected={i === cursor}
          class={[
            "flex w-full items-center gap-2 px-3 py-1.5 text-left text-[13px]",
            i === cursor ? "bg-accent/20 text-white" : "text-fg/90",
          ]}
          style={section === "font" ? `font-family: ${(row as FontOption).stack}` : undefined}
          onmouseenter={() => (cursor = i)}
          onclick={keep}
        >
          <span class="min-w-0 flex-1 truncate">{rowLabel(row)}</span>
          {#if section === "font"}
            <!-- The characters that actually decide a coding face. -->
            <span class="shrink-0 text-muted" style="font-family: {(row as FontOption).stack}">
              il1 O0 {"{}"} =&gt;
            </span>
          {:else if (row as ThemeEntry).kind === "custom"}
            <span class="shrink-0 rounded border border-accent/40 px-1 text-[10px] text-accent/90">custom</span>
          {/if}
          {#if isCurrent(row)}
            <span class="shrink-0 text-[11px] text-muted">applied</span>
          {/if}
        </button>
      </li>
    {:else}
      <li class="px-3 py-2 text-[13px] text-muted">Nothing matches “{query}”.</li>
    {/each}
  </ul>

  <p class="border-t border-border px-3 py-2 text-[11px] text-muted">
    {#if failed}
      <span class="text-red-400">{failed}</span>
    {:else}
      ↑↓ preview · ⇥ {section === "theme" ? "fonts" : "themes"} · Enter keep · Esc revert
      {#if section === "theme"}
        · drop VS Code theme JSON in <code class="rounded bg-canvas px-1">~/.codrift/themes</code>
      {:else}
        · <kbd class="rounded bg-canvas px-1">+</kbd>/<kbd class="rounded bg-canvas px-1">−</kbd> resize
      {/if}
    {/if}
  </p>
</Overlay>

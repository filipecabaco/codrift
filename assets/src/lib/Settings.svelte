<script lang="ts" module>
  export type SettingsSection = "general" | "appearance" | "profiles" | "integrations" | "keyboard";
</script>

<script lang="ts">
  // One window for everything that used to be its own floating panel. The
  // separate overlays each answered one question well and left the others
  // undiscoverable — a launch profile and a default folder are the same kind of
  // decision, and looking for either meant knowing which icon it hid behind.
  //
  // The spine is the section list: it is what you arrow through, and every
  // panel to its right is a plain component with no scrim or Esc of its own.
  import Overlay from "$lib/Overlay.svelte";
  import Appearance from "$lib/Appearance.svelte";
  import Integrations from "$lib/Integrations.svelte";
  import Profiles from "$lib/Profiles.svelte";
  import SettingsGeneral from "$lib/SettingsGeneral.svelte";
  import SettingsKeyboard from "$lib/SettingsKeyboard.svelte";
  import type { Keymap } from "$lib/keys";

  let {
    section = $bindable("general"),
    keymap,
    onClose,
    onChanged,
  }: {
    section?: SettingsSection;
    keymap: Keymap;
    onClose: () => void;
    /** Something in settings.json changed — the app re-reads profiles and defaults. */
    onChanged?: () => void;
  } = $props();

  const SECTIONS: { id: SettingsSection; label: string; blurb: string }[] = [
    { id: "general", label: "General", blurb: "Workspace folder, default agent" },
    { id: "appearance", label: "Appearance", blurb: "Theme and font" },
    { id: "profiles", label: "Launch profiles", blurb: "Accounts, commands, env" },
    { id: "integrations", label: "Integrations", blurb: "Issue trackers" },
    { id: "keyboard", label: "Keyboard", blurb: "Shortcut reference" },
  ];

  // The section list is ONE tab stop, not five: ↑↓ move within it and ⇥ leaves
  // for the panel. Tabbing through every section to reach the thing you came
  // here to change is the failure this pattern exists to prevent.
  let navEl = $state<HTMLElement | null>(null);
  // Panels that can absorb an Esc (back out of a draft, abandon an auth flow)
  // expose `onEscape`; the rest let it close the window.
  let panel = $state<{ onEscape?: () => boolean } | null>(null);

  function focusNav(id: SettingsSection) {
    navEl?.querySelector<HTMLElement>(`[data-section="${id}"]`)?.focus();
  }

  function step(delta: number, moveFocus: boolean) {
    const i = SECTIONS.findIndex((s) => s.id === section);
    const next = SECTIONS[Math.min(Math.max(i + delta, 0), SECTIONS.length - 1)];
    if (!next || next.id === section) return;
    section = next.id;
    if (moveFocus) requestAnimationFrame(() => focusNav(next.id));
  }

  function close() {
    // Give the panel first refusal: Esc in a half-written profile means "drop
    // the draft", not "throw away the window it was in".
    if (panel?.onEscape?.()) return;
    onClose();
  }

  function navKeydown(e: KeyboardEvent) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      step(1, true);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      step(-1, true);
    }
  }

  // Section switching from anywhere inside the window, including out of a text
  // field — the nav's own ↑↓ only reach as far as the nav.
  function panelKeydown(e: KeyboardEvent) {
    if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    e.preventDefault();
    e.stopPropagation();
    step(e.key === "ArrowDown" ? 1 : -1, false);
  }
</script>

<!-- Capture, so ⌃↑/⌃↓ reach us from inside a panel's own text field. -->
<svelte:window onkeydowncapture={panelKeydown} />

<!-- ownsTab: the panels bind Tab themselves (path completion, theme/font). -->
<Overlay label="Settings" width="880px" top="7vh" padded={false} ownsTab onClose={close}>
  <div class="flex h-[74vh] min-h-0">
    <nav
      bind:this={navEl}
      aria-label="Settings sections"
      class="flex w-52 shrink-0 flex-col border-r border-border bg-canvas/40 p-2"
    >
      <h2 class="px-2 pt-1 pb-2 text-[11px] font-semibold tracking-wide text-muted uppercase">
        Settings
      </h2>
      {#each SECTIONS as s (s.id)}
        <button
          data-section={s.id}
          onkeydown={navKeydown}
          aria-current={section === s.id ? "page" : undefined}
          {...{ tabindex: section === s.id ? 0 : -1 }}
          class={[
            "rounded-md px-2 py-1.5 text-left outline-none",
            section === s.id ? "bg-accent/20 text-fg" : "text-fg/80 hover:bg-canvas",
            "focus-visible:ring-1 focus-visible:ring-accent",
          ]}
          onclick={() => (section = s.id)}
        >
          <span class="block text-[12px]">{s.label}</span>
          <span class="block truncate text-[10px] text-muted">{s.blurb}</span>
        </button>
      {/each}
      <p class="mt-auto px-2 pt-2 text-[10px] leading-4 text-muted">
        ↑↓ section · ⌃↑ ⌃↓ from anywhere · ⇥ into the panel · Esc close
      </p>
    </nav>

    <div class="min-w-0 flex-1">
      {#if section === "general"}
        <SettingsGeneral {onChanged} />
      {:else if section === "appearance"}
        <Appearance />
      {:else if section === "profiles"}
        <Profiles bind:this={panel} {onChanged} />
      {:else if section === "integrations"}
        <Integrations bind:this={panel} />
      {:else}
        <SettingsKeyboard {keymap} />
      {/if}
    </div>
  </div>
</Overlay>

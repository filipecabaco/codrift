<script lang="ts">
  // The one floating-overlay shell: palette, prompt, dir picker, confirm,
  // integrations. Owns the scrim, Esc, backdrop dismissal and the focus trap.
  import type { Snippet } from "svelte";

  let {
    label,
    width = "460px",
    top = "18vh",
    padded = true,
    ownsTab = false,
    onClose,
    children,
  }: {
    /** Accessible name for the dialog. */
    label: string;
    width?: string;
    top?: string;
    /** False when the content draws its own edge-to-edge sections (palette, picker). */
    padded?: boolean;
    /** True when the content binds Tab itself; skips the focus trap's Tab cycling. */
    ownsTab?: boolean;
    onClose: () => void;
    children: Snippet;
  } = $props();

  let panel = $state<HTMLElement | null>(null);
  let restoreTo: HTMLElement | null = null;

  const FOCUSABLE =
    'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

  function focusables(): HTMLElement[] {
    return panel ? Array.from(panel.querySelectorAll<HTMLElement>(FOCUSABLE)) : [];
  }

  $effect(() => {
    restoreTo = document.activeElement as HTMLElement | null;
    // Let the content's own autofocus win; only pull focus in if nothing took it.
    queueMicrotask(() => {
      if (panel && !panel.contains(document.activeElement)) focusables()[0]?.focus();
    });
    return () => restoreTo?.focus?.();
  });

  // Capture phase: a terminal underneath would otherwise swallow these.
  function onKeydown(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      onClose();
      return;
    }
    if (e.key !== "Tab" || ownsTab) return;

    const items = focusables();
    if (items.length === 0) return;
    const first = items[0];
    const last = items[items.length - 1];
    const current = document.activeElement as HTMLElement | null;

    if (e.shiftKey && (current === first || !panel?.contains(current))) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && current === last) {
      e.preventDefault();
      first.focus();
    }
  }
</script>

<svelte:window onkeydowncapture={onKeydown} />

<!-- Scrim is a click target only; Esc is its keyboard equivalent. -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<div
  class="fixed inset-0 z-50 flex items-start justify-center bg-black/50"
  style="padding-top: {top}"
  onclick={onClose}
  role="presentation"
>
  <div
    bind:this={panel}
    class={[
      "max-w-[90vw] overflow-hidden rounded-lg border border-border bg-surface shadow-2xl",
      padded && "p-4",
    ]}
    style="width: {width}"
    onclick={(e) => e.stopPropagation()}
    role="dialog"
    aria-modal="true"
    aria-label={label}
    tabindex="-1"
  >
    {@render children()}
  </div>
</div>

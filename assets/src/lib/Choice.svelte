<script lang="ts">
  // A modal that asks one question with a handful of answers.
  //
  // Every option carries its own number key. Codrift is keyboard-first
  // everywhere else — j/k in the sidebar, ⌘1/⌘2 for panes — and a dialog that
  // forced a reach for the mouse (or three Tabs) was the one place that broke.
  // The badge is the shortcut: what you read is what you press.
  import Overlay from "$lib/Overlay.svelte";

  export type ChoiceOption = {
    label: string;
    /** One line under the label saying what picking it actually does. */
    hint?: string;
    /** May be async. Throwing keeps the dialog open and shows the reason. */
    run: () => void | Promise<void>;
  };

  let {
    title,
    description,
    options,
    cancelLabel = "Cancel",
    onClose,
  }: {
    title: string;
    description?: string;
    options: ChoiceOption[];
    cancelLabel?: string;
    onClose: () => void;
  } = $props();

  let cursor = $state(0);
  let busy = $state<number | null>(null);
  let error = $state<string | null>(null);
  let list = $state<HTMLElement | null>(null);

  // Arrow keys move the highlight, so they have to move DOM focus with it —
  // otherwise Space (which clicks the *focused* button) picks a different
  // option than the one the highlight is on.
  function focusOption(i: number) {
    cursor = i;
    list?.querySelectorAll<HTMLElement>("button[data-index]")[i]?.focus();
  }

  // Past nine there is no number key left to press, so the numbering stops
  // rather than lying about a shortcut that does nothing.
  const NUMBERED = 9;

  async function pick(i: number) {
    const option = options[i];
    if (!option || busy !== null) return;
    cursor = i;
    busy = i;
    error = null;
    try {
      await option.run();
    } catch (e) {
      error = (e as Error).message ?? "Something went wrong.";
      busy = null;
    }
  }

  // Capture phase, like Confirm and Overlay: a terminal underneath would
  // otherwise swallow these before the dialog ever sees them.
  function onkeydown(e: KeyboardEvent) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;

    const digit = Number(e.key);
    if (Number.isInteger(digit) && digit >= 1 && digit <= Math.min(options.length, NUMBERED)) {
      e.preventDefault();
      e.stopPropagation();
      void pick(digit - 1);
      return;
    }

    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      e.stopPropagation();
      const delta = e.key === "ArrowDown" ? 1 : -1;
      focusOption((cursor + delta + options.length) % options.length);
      return;
    }

    if (e.key === "Enter") {
      e.preventDefault();
      e.stopPropagation();
      void pick(cursor);
    }
  }
</script>

<svelte:window onkeydowncapture={onkeydown} />

<Overlay label={title} width="480px" onClose={busy === null ? onClose : () => {}}>
  <h3 class="text-[13px] font-semibold text-fg">{title}</h3>
  {#if description}
    <p class="mt-1 text-[12px] leading-5 text-fg/70">{description}</p>
  {/if}

  {#if error}
    <p class="mt-3 rounded-md bg-red-500/10 px-2.5 py-2 text-[12px] text-red-300" role="alert">
      {error}
    </p>
  {/if}

  <div bind:this={list} class="mt-3 flex flex-col gap-1.5">
    {#each options as option, i (option.label)}
      <button
        data-index={i}
        class={[
          "flex w-full items-start gap-2.5 rounded-lg border px-3 py-2.5 text-left disabled:opacity-50",
          i === cursor ? "border-accent bg-accent/10" : "border-border bg-surface hover:border-accent/50",
        ]}
        disabled={busy !== null}
        onmouseenter={() => (cursor = i)}
        onclick={() => pick(i)}
      >
        <kbd
          class={[
            "mt-px shrink-0 rounded border px-1.5 py-px text-[10px] leading-4 tabular-nums",
            i === cursor ? "border-accent/60 bg-accent/20 text-accent" : "border-border text-muted",
          ]}
        >
          {i < NUMBERED ? i + 1 : "·"}
        </kbd>
        <span class="min-w-0 flex-1">
          <span class="block text-[13px] font-semibold text-fg">{option.label}</span>
          {#if option.hint}
            <span class="mt-0.5 block text-[12px] leading-5 text-fg/60">{option.hint}</span>
          {/if}
        </span>
        {#if busy === i}<span class="mt-px shrink-0 text-[11px] text-muted">working…</span>{/if}
      </button>
    {/each}
  </div>

  <div class="mt-3 flex items-center justify-between">
    <p class="text-[11px] text-muted">
      {options.length > 1 ? `1–${Math.min(options.length, NUMBERED)} to choose · ` : ""}↑↓ then Enter
      · Esc to cancel
    </p>
    <button
      class="rounded-md px-2.5 py-1 text-xs text-muted hover:text-fg disabled:opacity-40"
      disabled={busy !== null}
      onclick={onClose}
    >
      {cancelLabel}
    </button>
  </div>
</Overlay>

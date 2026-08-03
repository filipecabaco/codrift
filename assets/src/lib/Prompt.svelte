<script lang="ts">
  import Overlay from "$lib/Overlay.svelte";

  let {
    title,
    placeholder = "",
    onSubmit,
    onClose,
  }: {
    title: string;
    placeholder?: string;
    onSubmit: (value: string) => void;
    onClose: () => void;
  } = $props();

  let value = $state("");
  let input: HTMLInputElement;

  $effect(() => {
    input?.focus();
    input?.select();
  });

  function onkeydown(e: KeyboardEvent) {
    if (e.key !== "Enter") return; // Esc is handled by Overlay
    e.preventDefault();
    const v = value.trim();
    if (v) onSubmit(v);
  }
</script>

<Overlay label={title} {onClose}>
  <h3 class="mb-2 text-[13px] font-semibold text-fg">{title}</h3>
  <input
    bind:this={input}
    bind:value
    {onkeydown}
    {placeholder}
    name="prompt"
    aria-label={title}
    class="w-full rounded-md border border-border bg-canvas px-3 py-2 text-sm text-fg outline-none focus:border-accent"
  />
  <p class="mt-2 text-[11px] text-muted">Enter to confirm · Esc to cancel</p>
</Overlay>

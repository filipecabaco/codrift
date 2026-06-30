<script lang="ts">
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
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
    } else if (e.key === "Enter") {
      e.preventDefault();
      const v = value.trim();
      if (v) onSubmit(v);
    }
  }
</script>

<div
  class="fixed inset-0 z-50 flex items-start justify-center bg-black/50 pt-[18vh]"
  onclick={onClose}
  role="presentation"
>
  <div
    class="w-[460px] max-w-[90vw] rounded-lg border border-border bg-surface p-4 shadow-2xl"
    onclick={(e) => e.stopPropagation()}
    role="presentation"
  >
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
  </div>
</div>

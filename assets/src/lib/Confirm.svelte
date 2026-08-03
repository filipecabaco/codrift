<script lang="ts">
  import Overlay from "$lib/Overlay.svelte";

  let {
    message,
    confirmLabel = "Confirm",
    onConfirm,
    onClose,
  }: {
    message: string;
    confirmLabel?: string;
    onConfirm: () => void;
    onClose: () => void;
  } = $props();

  // Enter confirms from anywhere in the dialog; Esc is Overlay's.
  function onkeydown(e: KeyboardEvent) {
    if (e.key !== "Enter") return;
    e.preventDefault();
    e.stopPropagation();
    onConfirm();
  }
</script>

<svelte:window onkeydowncapture={onkeydown} />

<Overlay label={message} width="420px" {onClose}>
  <p class="mb-1 text-[13px] text-fg">{message}</p>
  <p class="mb-4 text-[11px] text-muted">Enter to confirm · Esc to cancel</p>
  <div class="flex justify-end gap-2">
    <button class="rounded-md px-3 py-1.5 text-xs text-muted hover:text-fg" onclick={onClose}>
      Cancel
    </button>
    <button
      class="rounded-md bg-red-500/20 px-3 py-1.5 text-xs text-red-300 hover:bg-red-500/30"
      onclick={onConfirm}
    >
      {confirmLabel}
    </button>
  </div>
</Overlay>

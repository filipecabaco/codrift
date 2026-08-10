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
    /** May be async. Resolving means "done" — the caller closes the dialog.
     *  Throwing keeps the dialog open and shows the reason. */
    onConfirm: () => void | Promise<void>;
    onClose: () => void;
  } = $props();

  // The action can be slow (stopping an agent, deleting an initiative) or fail
  // outright. Without these, a rejected action left the dialog dismissed and the
  // failure invisible, so the button read as broken.
  let busy = $state(false);
  let error = $state<string | null>(null);

  async function run() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      await onConfirm();
    } catch (e) {
      error = (e as Error).message ?? "Something went wrong.";
      busy = false;
    }
  }

  // Enter confirms from anywhere in the dialog; Esc is Overlay's.
  function onkeydown(e: KeyboardEvent) {
    if (e.key !== "Enter") return;
    e.preventDefault();
    e.stopPropagation();
    void run();
  }
</script>

<svelte:window onkeydowncapture={onkeydown} />

<Overlay label={message} width="420px" onClose={busy ? () => {} : onClose}>
  <p class="mb-1 text-[13px] text-fg">{message}</p>
  <p class="mb-4 text-[11px] text-muted">Enter to confirm · Esc to cancel</p>
  {#if error}
    <p class="mb-3 rounded-md bg-red-500/10 px-2.5 py-2 text-[12px] text-red-300" role="alert">
      {error}
    </p>
  {/if}
  <div class="flex justify-end gap-2">
    <button
      class="rounded-md px-3 py-1.5 text-xs text-muted hover:text-fg disabled:opacity-40"
      disabled={busy}
      onclick={onClose}
    >
      Cancel
    </button>
    <button
      class="rounded-md bg-red-500/20 px-3 py-1.5 text-xs text-red-300 hover:bg-red-500/30 disabled:opacity-40"
      disabled={busy}
      onclick={run}
    >
      {busy ? "Working…" : confirmLabel}
    </button>
  </div>
</Overlay>

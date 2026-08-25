<script lang="ts">
  import DirField from "$lib/DirField.svelte";
  import Overlay from "$lib/Overlay.svelte";

  let {
    onSubmit,
    onClose,
    start,
  }: {
    onSubmit: (path: string) => void;
    onClose: () => void;
    /**
     * Where browsing begins — the workspace folder from Settings when there is
     * one, otherwise home. Most repos live under one parent folder, and `~`
     * meant retyping the same two segments on every add.
     */
    start?: string | null;
  } = $props();

  // A trailing slash makes the first listing that folder's children rather than
  // its siblings filtered by its own name. Read once on purpose: this is the
  // field's starting point, and a later settings change must not yank the path
  // out from under someone mid-type.
  // svelte-ignore state_referenced_locally
  let value = $state(((start ?? "~").replace(/\/+$/, "") || "/") + "/");
</script>

<!-- ownsTab: the field spends Tab on path completion, not on cycling focus. -->
<Overlay label="Add directory" width="520px" top="12vh" padded={false} ownsTab {onClose}>
  <div class="px-3 pt-3">
    <h3 class="mb-2 text-[13px] font-semibold text-fg">Add directory</h3>
    <!-- The list bleeds to the panel edges: it is the picker's body, not an
         indented afterthought under the field. -->
    <DirField bind:value {onSubmit} autofocus listClass="max-h-72 -mx-3 mt-3 border-t border-border" />
  </div>
  <p class="border-t border-border px-3 py-2 text-[11px] text-muted">
    Tab to complete · ↑↓ to navigate · Enter to add · Esc to cancel
  </p>
</Overlay>

<script lang="ts">
  // The two answers Codrift keeps asking for and shouldn't: where your repos
  // live, and which agent a new initiative starts with.
  import DirField from "$lib/DirField.svelte";
  import { ADAPTERS, setDefaultAgent, setWorkspaceDir } from "$lib/api";
  import { workspace as ws } from "$lib/workspace.svelte";

  let { onChanged }: { onChanged?: () => void } = $props();

  // Seeded once: re-deriving from the store would overwrite what is being typed
  // the moment a refresh lands.
  let dir = $state(ws.workspaceDir ?? "");
  let saving = $state(false);
  let error = $state<string | null>(null);
  let saved = $state(false);

  const dirty = $derived(dir.trim().replace(/\/+$/, "") !== (ws.workspaceDir ?? ""));

  async function saveDir() {
    saving = true;
    error = null;
    try {
      // A trailing slash is how you browse *into* a folder, not part of its
      // name — storing it would show up in every hint that echoes the path.
      const trimmed = dir.trim().replace(/\/+$/, "");
      ws.workspaceDir = await setWorkspaceDir(trimmed);
      dir = ws.workspaceDir ?? "";
      saved = true;
      setTimeout(() => (saved = false), 2000);
      onChanged?.();
    } catch (e) {
      error = (e as Error).message;
    } finally {
      saving = false;
    }
  }

  async function clearDir() {
    dir = "";
    await saveDir();
  }

  async function pickDefaultAgent(next: string) {
    error = null;
    const previous = ws.defaultAgent;
    ws.defaultAgent = next;
    try {
      await setDefaultAgent(next);
      onChanged?.();
    } catch (e) {
      ws.defaultAgent = previous;
      error = (e as Error).message;
    }
  }
</script>

<div class="flex h-full min-h-0 flex-col">
  <div class="border-b border-border px-4 py-3">
    <h2 class="text-[13px] font-semibold text-fg">General</h2>
    <p class="text-[11px] text-muted">Where your work lives and what it starts with.</p>
  </div>

  {#if error}
    <p class="border-b border-red-500/30 bg-red-500/10 px-4 py-2 text-[11px] text-red-300">{error}</p>
  {/if}

  <div class="min-h-0 flex-1 overflow-y-auto px-4 py-3">
    <section>
      <h3 class="text-[12px] font-semibold text-fg">Default workspace folder</h3>
      <p class="mt-0.5 mb-2 text-[11px] text-muted">
        Where “Add directory” starts browsing. Most repos sit under one parent folder, and starting
        at <code class="rounded bg-canvas px-1">~</code> means retyping the same two segments every
        time.
      </p>

      <DirField
        bind:value={dir}
        label="Default workspace folder"
        placeholder="~/Documents/workspace"
        listClass="max-h-44 mt-2 rounded-md border border-border"
        onSubmit={saveDir}
      />

      <div class="mt-2 flex items-center gap-2">
        <span class="text-[11px] text-muted">
          {#if saved}
            Saved.
          {:else if ws.workspaceDir}
            Currently <code class="rounded bg-canvas px-1">{ws.workspaceDir}</code>
          {:else}
            Not set — the picker starts at <code class="rounded bg-canvas px-1">~</code>.
          {/if}
        </span>
        {#if ws.workspaceDir}
          <button
            class="ml-auto rounded-md border border-border px-2.5 py-1 text-[11px] text-muted hover:text-fg"
            onclick={clearDir}
          >
            Reset to ~
          </button>
        {/if}
        <button
          class={[
            "rounded-md bg-accent/20 px-2.5 py-1 text-[11px] text-accent hover:bg-accent/30 disabled:opacity-40",
            ws.workspaceDir ? "" : "ml-auto",
          ]}
          disabled={saving || !dirty}
          onclick={saveDir}
        >
          {saving ? "Saving…" : "Save folder"}
        </button>
      </div>
    </section>

    <section class="mt-6 border-t border-border pt-4">
      <h3 class="text-[12px] font-semibold text-fg">Default agent</h3>
      <p class="mt-0.5 mb-2 text-[11px] text-muted">
        What a new initiative launches when you don't pick something else. Each initiative can
        override it — from its Context view, or with the “Change this initiative's agent” command.
      </p>
      <select
        aria-label="Default agent for new initiatives"
        value={ws.defaultAgent}
        onchange={(e) => pickDefaultAgent(e.currentTarget.value)}
        class="rounded-md border border-border bg-canvas px-2 py-1.5 text-xs text-fg"
      >
        {#each ADAPTERS as a (a)}
          <option value={a}>{a}</option>
        {/each}
        {#if ws.profiles.length}
          <optgroup label="Profiles">
            {#each ws.profiles as p (p.name)}
              <option value={p.name}>{p.name}</option>
            {/each}
          </optgroup>
        {/if}
      </select>
    </section>
  </div>

  <p class="shrink-0 border-t border-border px-4 py-2 text-[11px] text-muted">
    Stored in <code class="rounded bg-canvas px-1">~/.codrift/settings.json</code>
  </p>
</div>

<script lang="ts">
  // Launch profiles, editable in the app instead of by hand in settings.json.
  // A profile is a base adapter plus the env that decides which account it runs
  // as — so "claude-personal" and "claude-work" are the same binary pointed at
  // different config folders. The list is the view; one row expands into the
  // form, so adding a profile and correcting one look the same.
  import { onMount } from "svelte";
  import { Icon } from "@steeze-ui/svelte-icon";
  import { Plus, Trash } from "@steeze-ui/heroicons";
  import Overlay from "$lib/Overlay.svelte";
  import {
    ADAPTERS,
    PROFILE_CONFIG_VAR,
    deleteAgentProfile,
    getAgentProfiles,
    saveAgentProfile,
    type AgentProfileConfig,
  } from "$lib/api";

  let { onClose, onChanged }: { onClose: () => void; onChanged?: () => void } = $props();

  // Env is edited as ordered rows, not a map: a map would reorder on every
  // keystroke and drop a row the moment two keys collided mid-typing.
  type EnvRow = { key: string; value: string };
  type ArgRow = { value: string };
  type Draft = {
    name: string;
    adapter: string;
    command: string;
    args: ArgRow[];
    env: EnvRow[];
    previousName: string | null;
  };

  let profiles = $state<AgentProfileConfig[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let saving = $state(false);
  let draft = $state<Draft | null>(null);
  let confirmDelete = $state<string | null>(null);
  let nameInput = $state<HTMLInputElement | null>(null);

  const toRows = (env: Record<string, string>): EnvRow[] =>
    Object.entries(env).map(([key, value]) => ({ key, value }));

  // Blank rows are scaffolding, not data — a half-typed row must not save.
  const toEnv = (rows: EnvRow[]): Record<string, string> =>
    Object.fromEntries(
      rows
        .map((r) => [r.key.trim(), r.value.trim()] as const)
        .filter(([key]) => key !== ""),
    );

  const toArgRows = (args: string[] | undefined): ArgRow[] =>
    (args ?? []).map((value) => ({ value }));

  const toArgs = (rows: ArgRow[]): string[] =>
    rows.map((r) => r.value.trim()).filter((v) => v !== "");

  const envSummary = (p: AgentProfileConfig) => {
    const parts = Object.entries(p.env).map(([k, v]) => `${k}=${v}`);
    const invocation = [p.command, ...(p.args ?? [])].filter(Boolean).join(" ");
    if (invocation) parts.unshift(`$ ${invocation}`);
    return parts.length ? parts.join(" · ") : "runs the base adapter, no overrides";
  };

  async function refresh() {
    try {
      profiles = await getAgentProfiles();
      error = null;
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  function newDraft() {
    confirmDelete = null;
    draft = {
      name: "",
      adapter: "claude",
      command: "",
      args: [],
      env: [{ key: PROFILE_CONFIG_VAR.claude, value: "" }],
      previousName: null,
    };
    focusName();
  }

  function editDraft(p: AgentProfileConfig) {
    confirmDelete = null;
    draft = {
      name: p.name,
      adapter: p.adapter ?? "claude",
      command: p.command ?? "",
      args: toArgRows(p.args),
      env: toRows(p.env),
      previousName: p.name,
    };
    focusName();
  }

  function focusName() {
    requestAnimationFrame(() => nameInput?.focus());
  }

  // Switching the base tool on a fresh profile re-points the suggested variable:
  // CLAUDE_CONFIG_DIR means nothing to codex. Only ever touches an untouched
  // suggestion, never a value someone typed.
  function onAdapterChange(next: string) {
    if (!draft) return;
    const suggested = PROFILE_CONFIG_VAR[draft.adapter];
    draft.adapter = next;
    const only = draft.env.length === 1 ? draft.env[0] : null;
    if (only && only.value.trim() === "" && (only.key === suggested || only.key === "")) {
      only.key = PROFILE_CONFIG_VAR[next] ?? "";
    }
  }

  async function save() {
    if (!draft) return;
    saving = true;
    error = null;
    try {
      await saveAgentProfile({
        name: draft.name.trim(),
        adapter: draft.adapter,
        command: draft.command.trim(),
        args: toArgs(draft.args),
        env: toEnv(draft.env),
        ...(draft.previousName ? { previous_name: draft.previousName } : {}),
      });
      draft = null;
      await refresh();
      onChanged?.();
    } catch (e) {
      error = (e as Error).message;
    } finally {
      saving = false;
    }
  }

  async function remove(name: string) {
    error = null;
    try {
      await deleteAgentProfile(name);
      confirmDelete = null;
      if (draft?.previousName === name) draft = null;
      await refresh();
      onChanged?.();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  // Dismissal backs out one level (confirm → form → panel) rather than throwing
  // away a half-written profile and the panel in one keystroke. Overlay routes
  // both Esc and the backdrop click here.
  function back() {
    if (confirmDelete) confirmDelete = null;
    else if (draft) draft = null;
    else onClose();
  }

  onMount(refresh);
</script>

<Overlay label="Launch profiles" width="620px" top="10vh" padded={false} onClose={back}>
  <div class="flex items-center justify-between gap-4 border-b border-border px-4 py-3">
    <div>
      <h2 class="text-[13px] font-semibold text-fg">Launch profiles</h2>
      <p class="text-[11px] text-muted">
        A named agent you can launch: its own command and config folder, so
        <code class="rounded bg-canvas px-1">claude-work</code> and
        <code class="rounded bg-canvas px-1">claude-personal</code> stay separate accounts.
      </p>
    </div>
    <button
      class="flex shrink-0 items-center gap-1.5 rounded-md bg-accent/20 px-2.5 py-1 text-[11px] text-accent hover:bg-accent/30"
      onclick={newDraft}
    >
      <Icon src={Plus} class="size-3.5" /> New profile
    </button>
  </div>

  {#if error}
    <p class="border-b border-red-500/30 bg-red-500/10 px-4 py-2 text-[11px] text-red-300">{error}</p>
  {/if}

  <div class="max-h-[52vh] min-h-0 overflow-y-auto p-2">
    {#if loading}
      <p class="p-3 text-xs text-muted">Loading…</p>
    {:else}
      {#each profiles as p (p.name)}
        <div class="rounded-md px-2 py-2 hover:bg-canvas/60">
          <div class="flex items-center gap-2.5">
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <span class="truncate text-xs font-semibold text-fg">{p.name}</span>
                <span class="shrink-0 rounded border border-border px-1.5 text-[10px] text-muted">
                  {p.adapter ?? "claude"}
                </span>
              </div>
              <p class="truncate text-[11px] text-muted" title={envSummary(p)}>
                {envSummary(p)}
              </p>
            </div>
            <button
              class="shrink-0 rounded-md border border-border px-2.5 py-1 text-[11px] text-muted hover:text-fg"
              onclick={() => editDraft(p)}
            >
              Edit
            </button>
            <button
              class="shrink-0 rounded-md p-1 text-muted hover:text-red-400"
              title="Delete profile"
              aria-label="Delete profile {p.name}"
              onclick={() => (confirmDelete = confirmDelete === p.name ? null : p.name)}
            >
              <Icon src={Trash} class="size-3.5" />
            </button>
          </div>

          {#if confirmDelete === p.name}
            <div class="mt-2 flex items-center gap-2 rounded-md border border-border bg-canvas p-2 text-[11px]">
              <span class="text-fg/80">Delete “{p.name}”? Running agents keep going.</span>
              <button class="ml-auto text-muted hover:text-fg" onclick={() => (confirmDelete = null)}>
                Cancel
              </button>
              <button class="rounded bg-red-500/20 px-2 py-0.5 text-red-300 hover:bg-red-500/30" onclick={() => remove(p.name)}>
                Delete
              </button>
            </div>
          {/if}
        </div>
      {:else}
        <div class="px-3 py-4 text-[12px] leading-6 text-muted">
          <p class="text-fg/80">No profiles yet.</p>
          <p>
            A profile lets you start agents as a specific account — say
            <code class="rounded bg-canvas px-1">claude-personal</code> pointing at
            <code class="rounded bg-canvas px-1">~/.claude-personal</code>. Log in there once with
            <code class="rounded bg-canvas px-1">CLAUDE_CONFIG_DIR=~/.claude-personal claude</code>,
            then pick the profile in the Launch dropdown.
          </p>
        </div>
      {/each}
    {/if}
  </div>

  {#if draft}
    <div class="border-t border-border bg-canvas/40 px-4 py-3">
      <div class="flex items-end gap-3">
        <label class="flex-1">
          <span class="mb-1 block text-[11px] text-muted">Name</span>
          <input
            bind:this={nameInput}
            bind:value={draft.name}
            placeholder="claude-personal"
            autocomplete="off"
            spellcheck="false"
            class="w-full rounded-md border border-border bg-canvas px-2 py-1.5 text-xs text-fg outline-none focus:border-accent"
          />
        </label>
        <label class="w-40">
          <span class="mb-1 block text-[11px] text-muted">Base adapter</span>
          <select
            value={draft.adapter}
            onchange={(e) => onAdapterChange(e.currentTarget.value)}
            class="w-full rounded-md border border-border bg-canvas px-2 py-1.5 text-xs text-fg"
          >
            {#each ADAPTERS as a (a)}
              <option value={a}>{a}</option>
            {/each}
            {#if !(ADAPTERS as readonly string[]).includes(draft.adapter)}
              <option value={draft.adapter}>{draft.adapter}</option>
            {/if}
          </select>
        </label>
      </div>

      <div class="mt-3">
        <label class="block">
          <span class="mb-1 block text-[11px] text-muted">
            Command — leave empty to run the base adapter's own executable
          </span>
          <input
            bind:value={draft.command}
            placeholder={draft.adapter}
            autocomplete="off"
            spellcheck="false"
            class="w-full rounded-md border border-border bg-canvas px-2 py-1.5 font-mono text-[11px] text-fg outline-none focus:border-accent"
          />
        </label>
        <p class="mt-1 text-[11px] text-muted">
          A bare name is looked up in <code class="rounded bg-canvas px-1">PATH</code> (a wrapper
          script like <code class="rounded bg-canvas px-1">claude-work</code>); anything with a
          <code class="rounded bg-canvas px-1">/</code> is a path.
        </p>
      </div>

      <div class="mt-3">
        <span class="mb-1 block text-[11px] text-muted">
          Arguments — appended to the ones {draft.adapter} passes itself, one per row
        </span>
        {#each draft.args as row, i (i)}
          <div class="mb-1 flex items-center gap-2">
            <span class="w-6 shrink-0 text-right font-mono text-[11px] text-muted">{i + 1}</span>
            <input
              bind:value={row.value}
              placeholder={i === 0 ? "--model" : "opus"}
              autocomplete="off"
              spellcheck="false"
              aria-label="Argument {i + 1}"
              class="min-w-0 flex-1 rounded-md border border-border bg-canvas px-2 py-1 font-mono text-[11px] text-fg outline-none focus:border-accent"
            />
            <button
              class="shrink-0 rounded-md p-1 text-muted hover:text-red-400"
              aria-label="Remove argument {i + 1}"
              onclick={() => (draft!.args = draft!.args.filter((_, j) => j !== i))}
            >
              <Icon src={Trash} class="size-3.5" />
            </button>
          </div>
        {/each}
        <button
          class="mt-1 flex items-center gap-1 text-[11px] text-accent hover:underline"
          onclick={() => (draft!.args = [...draft!.args, { value: "" }])}
        >
          <Icon src={Plus} class="size-3" /> Add argument
        </button>
        <p class="mt-1 text-[11px] text-muted">
          One row per argument — <code class="rounded bg-canvas px-1">--model</code> and
          <code class="rounded bg-canvas px-1">opus</code> are two rows, so a value with spaces
          needs no quoting.
        </p>
      </div>

      <div class="mt-3">
        <span class="mb-1 block text-[11px] text-muted">
          Environment — applied to this agent's process only
        </span>
        {#each draft.env as row, i (i)}
          <div class="mb-1 flex items-center gap-2">
            <input
              bind:value={row.key}
              placeholder="CLAUDE_CONFIG_DIR"
              autocomplete="off"
              spellcheck="false"
              aria-label="Variable name"
              class="w-48 rounded-md border border-border bg-canvas px-2 py-1 font-mono text-[11px] text-fg outline-none focus:border-accent"
            />
            <input
              bind:value={row.value}
              placeholder="~/.claude-personal"
              autocomplete="off"
              spellcheck="false"
              aria-label="Value"
              class="min-w-0 flex-1 rounded-md border border-border bg-canvas px-2 py-1 font-mono text-[11px] text-fg outline-none focus:border-accent"
            />
            <button
              class="shrink-0 rounded-md p-1 text-muted hover:text-red-400"
              aria-label="Remove variable"
              onclick={() => (draft!.env = draft!.env.filter((_, j) => j !== i))}
            >
              <Icon src={Trash} class="size-3.5" />
            </button>
          </div>
        {/each}
        <button
          class="mt-1 flex items-center gap-1 text-[11px] text-accent hover:underline"
          onclick={() => (draft!.env = [...draft!.env, { key: "", value: "" }])}
        >
          <Icon src={Plus} class="size-3" /> Add variable
        </button>
      </div>

      <div class="mt-3 flex items-center gap-2">
        <p class="text-[11px] text-muted">
          <code class="rounded bg-canvas px-1">~</code> is expanded at launch. Log in to a new config
          folder once before using it.
        </p>
        <button class="ml-auto rounded-md border border-border px-2.5 py-1 text-[11px] text-muted hover:text-fg" onclick={() => (draft = null)}>
          Cancel
        </button>
        <button
          class="rounded-md bg-accent/20 px-2.5 py-1 text-[11px] text-accent hover:bg-accent/30 disabled:opacity-50"
          disabled={saving || draft.name.trim() === ""}
          onclick={save}
        >
          {saving ? "Saving…" : draft.previousName ? "Save changes" : "Create profile"}
        </button>
      </div>
    </div>
  {/if}

  <p class="border-t border-border px-4 py-2 text-[11px] text-muted">
    Stored in <code class="rounded bg-canvas px-1">~/.codrift/settings.json</code> · Esc to close
  </p>
</Overlay>

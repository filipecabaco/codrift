<script lang="ts">
  import { onMount } from "svelte";
  import { EditorView, basicSetup } from "codemirror";
  import { Compartment, Prec } from "@codemirror/state";
  import { keymap } from "@codemirror/view";
  import { acceptCompletion, closeCompletion, completionStatus } from "@codemirror/autocomplete";
  import { LanguageDescription } from "@codemirror/language";
  import { languages } from "@codemirror/language-data";
  import { vim, Vim } from "@replit/codemirror-vim";
  import { isImagePath, rpc } from "$lib/api";
  import { editorTheme } from "$lib/editor-theme";
  import { themeState } from "$lib/theme.svelte";
  import { fontState } from "$lib/fonts.svelte";
  import Confirm from "$lib/Confirm.svelte";

  let {
    initiativeId,
    path,
    onClose,
    onSaved,
  }: {
    initiativeId: string;
    path: string;
    onClose: () => void;
    /** Called after every successful write, so stale previews can re-read. */
    onSaved?: () => void;
  } = $props();

  let host: HTMLDivElement;
  let view: EditorView | undefined;
  // Swapped in place when the theme changes, so the buffer (and vim state)
  // survives a re-skin.
  const themeCompartment = new Compartment();
  let status = $state<string>("loading…");
  // What's on disk, as far as this editor knows.
  let savedDoc = "";
  let confirmingClose = $state(false);
  // CodeMirror's doc isn't reactive, so mirror the dirty flag into a rune.
  let dirty = $state(false);

  const isDirty = () => !!view && view.state.doc.toString() !== savedDoc;

  async function save() {
    if (!view) return;
    try {
      const content = view.state.doc.toString();
      const res = await rpc<{ bytes: number }>("write_file", {
        initiative_id: initiativeId,
        path,
        content,
      });
      savedDoc = content;
      dirty = isDirty();
      status = `saved · ${res.bytes} B`;
      onSaved?.();
    } catch (e) {
      status = (e as Error).message;
    }
  }

  // Vim's own contract: `:q` refuses to discard, `:q!` forces it.
  function requestClose(force = false) {
    if (force || !isDirty()) return onClose();
    confirmingClose = true;
    status = "unsaved changes — :w to save, :q! to discard";
  }

  $effect(() => {
    themeState.id;
    fontState.stack;
    fontState.size;
    view?.dispatch({ effects: themeCompartment.reconfigure(editorTheme()) });
  });

  onMount(() => {
    let destroyed = false;

    (async () => {
      // A picture opened as text is mojibake in a vim buffer that can then be
      // saved back over the original. The Tree pane hides Edit for these, but
      // the command palette and the context menu reach the same path.
      if (isImagePath(path) && !path.toLowerCase().endsWith(".svg")) {
        status = `${path.split("/").pop()} is an image — open it in the Tree preview instead.`;
        return;
      }

      let initial = "";
      try {
        const res = await rpc<{ content: string }>("read_file", {
          initiative_id: initiativeId,
          path,
        });
        initial = res.content;
      } catch (e) {
        status = (e as Error).message;
        return;
      }
      if (destroyed) return;

      savedDoc = initial;

      // :w / :wq / :q / :q! from vim, plus ⌘S / Ctrl+S.
      Vim.defineEx("write", "w", () => void save());
      Vim.defineEx("wq", "wq", () => void save().then(onClose));
      Vim.defineEx("quit", "q", (_cm: unknown, params: { argString?: string }) =>
        requestClose(params?.argString?.trim() === "!"),
      );
      const saveKey = keymap.of([
        { key: "Mod-s", preventDefault: true, run: () => (void save(), true) },
      ]);

      // vim() grabs Enter/Escape before autocomplete can. When the completion
      // popup is open, let Enter accept and Escape close it; otherwise fall
      // through (return false) so vim keeps its normal behaviour.
      const completionKeys = Prec.highest(
        keymap.of([
          {
            key: "Enter",
            run: (v) => (completionStatus(v.state) === "active" ? acceptCompletion(v) : false),
          },
          {
            key: "Escape",
            run: (v) => (completionStatus(v.state) != null ? closeCompletion(v) : false),
          },
        ]),
      );

      const lang = new Compartment();
      // vim() must come first in the extension list.
      view = new EditorView({
        doc: initial,
        extensions: [
          completionKeys,
          vim(),
          basicSetup,
          saveKey,
          themeCompartment.of(editorTheme()),
          EditorView.lineWrapping,
          EditorView.updateListener.of((u) => {
            if (u.docChanged) dirty = isDirty();
          }),
          lang.of([]),
        ],
        parent: host,
      });
      status = "vim · :w / ⌘S to save · :q to close";

      const desc = LanguageDescription.matchFilename(languages, path.split("/").pop() ?? path);
      if (desc) {
        const support = await desc.load();
        if (!destroyed) view.dispatch({ effects: lang.reconfigure(support) });
      }
      view.focus();
    })();

    return () => {
      destroyed = true;
      view?.destroy();
    };
  });
</script>

<div class="fixed inset-0 z-50 flex flex-col bg-canvas">
  <div class="flex items-center gap-3 border-b border-border bg-surface px-4 py-2">
    <span class="text-[13px] text-accent">{path}</span>
    {#if dirty}
      <span class="text-[11px] text-accent" title="Unsaved changes">●</span>
    {/if}
    <span class="text-[11px] text-muted">{status}</span>
    <button class="ml-auto rounded-md px-2 py-1 text-xs text-muted hover:text-fg" onclick={() => void save()}>
      Save
    </button>
    <button class="rounded-md px-2 py-1 text-xs text-muted hover:text-fg" onclick={() => requestClose()}>
      Close
    </button>
  </div>
  <div class="min-h-0 flex-1 overflow-hidden text-[13px]" bind:this={host}></div>
</div>

{#if confirmingClose}
  <Confirm
    message="Discard unsaved changes to {path.split('/').pop()}?"
    confirmLabel="Discard"
    onConfirm={() => {
      confirmingClose = false;
      onClose();
    }}
    onClose={() => {
      confirmingClose = false;
      view?.focus();
    }}
  />
{/if}

<script lang="ts">
  import { onMount } from "svelte";
  import { EditorView, basicSetup } from "codemirror";
  import { Compartment } from "@codemirror/state";
  import { keymap } from "@codemirror/view";
  import { LanguageDescription } from "@codemirror/language";
  import { languages } from "@codemirror/language-data";
  import { vim, Vim } from "@replit/codemirror-vim";
  import { githubDark } from "@uiw/codemirror-theme-github";
  import { rpc } from "$lib/api";

  let {
    initiativeId,
    path,
    onClose,
  }: { initiativeId: string; path: string; onClose: () => void } = $props();

  let host: HTMLDivElement;
  let view: EditorView | undefined;
  let status = $state<string>("loading…");

  async function save() {
    if (!view) return;
    try {
      const content = view.state.doc.toString();
      const res = await rpc<{ bytes: number }>("write_file", {
        initiative_id: initiativeId,
        path,
        content,
      });
      status = `saved · ${res.bytes} B`;
    } catch (e) {
      status = (e as Error).message;
    }
  }

  onMount(() => {
    let destroyed = false;

    (async () => {
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

      // :w / :wq / :q from vim, plus ⌘S / Ctrl+S.
      Vim.defineEx("write", "w", () => void save());
      Vim.defineEx("wq", "wq", () => void save().then(onClose));
      Vim.defineEx("quit", "q", () => onClose());
      const saveKey = keymap.of([
        { key: "Mod-s", preventDefault: true, run: () => (void save(), true) },
      ]);

      const lang = new Compartment();
      // vim() must come first in the extension list.
      view = new EditorView({
        doc: initial,
        extensions: [vim(), basicSetup, saveKey, githubDark, EditorView.lineWrapping, lang.of([])],
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
    <span class="text-[11px] text-muted">{status}</span>
    <button class="ml-auto rounded-md px-2 py-1 text-xs text-muted hover:text-fg" onclick={() => void save()}>
      Save
    </button>
    <button class="rounded-md px-2 py-1 text-xs text-muted hover:text-fg" onclick={onClose}>Close</button>
  </div>
  <div class="min-h-0 flex-1 overflow-hidden text-[13px]" bind:this={host}></div>
</div>

// Dropping a file onto an agent has to go through Tauri, not the DOM. WKWebView
// hands a `drop` event a `File` with no path — useful for uploading bytes,
// useless for telling an agent which file on this machine to read. Tauri's
// `tauri://drag-*` events carry the real absolute paths instead.
//
// The catch is that those events are window-global: they know where the pointer
// is, not which pane it is over. So panes register themselves here and we
// hit-test the pointer against them. Text and URL drags aren't intercepted by
// Tauri, so those still arrive as ordinary DOM events, handled per-zone.

/** What a drop delivered: native file paths, or dragged text. */
export type DropPayload = { paths?: string[]; text?: string };

type Zone = {
  el: HTMLElement;
  onDrop: (payload: DropPayload) => void;
  onHover: (over: boolean) => void;
};

const zones = new Set<Zone>();
let hovered: Zone | null = null;
let listening = false;

function zoneAt(x: number, y: number): Zone | null {
  // elementFromPoint honours stacking and overflow, so a modal or the pane on
  // top of a split can't claim a drop the user aimed somewhere else.
  const el = document.elementFromPoint(x, y);
  if (!el) return null;
  for (const zone of zones) if (zone.el.contains(el)) return zone;
  return null;
}

function setHover(zone: Zone | null) {
  if (hovered === zone) return;
  hovered?.onHover(false);
  hovered = zone;
  zone?.onHover(true);
}

type TauriDragPayload = { paths?: string[]; position?: { x: number; y: number } };
type TauriEvents = {
  listen: (event: string, handler: (e: { payload: TauriDragPayload }) => void) => Promise<unknown>;
};

function tauriEvents(): TauriEvents | null {
  return (window as unknown as { __TAURI__?: { event?: TauriEvents } }).__TAURI__?.event ?? null;
}

// Tauri reports physical pixels; the DOM works in CSS pixels, which on a retina
// display are half the size. Skipping this lands every drop in the top-left
// quadrant of the window.
function zoneAtPhysical(payload: TauriDragPayload): Zone | null {
  if (!payload.position) return null;
  const ratio = window.devicePixelRatio || 1;
  return zoneAt(payload.position.x / ratio, payload.position.y / ratio);
}

function listenForNativeDrags() {
  const events = tauriEvents();
  // A plain browser has no Tauri global — text drops still work, native file
  // drops simply have no paths to offer and are ignored.
  if (listening || !events) return;
  listening = true;

  events.listen("tauri://drag-enter", (e) => setHover(zoneAtPhysical(e.payload)));
  events.listen("tauri://drag-over", (e) => setHover(zoneAtPhysical(e.payload)));
  events.listen("tauri://drag-leave", () => setHover(null));
  events.listen("tauri://drag-drop", (e) => {
    const zone = zoneAtPhysical(e.payload);
    setHover(null);
    const paths = e.payload.paths ?? [];
    if (zone && paths.length) zone.onDrop({ paths });
  });
}

/** Make `el` accept dropped files and text. Returns an unregister function. */
export function registerDropZone(
  el: HTMLElement,
  handlers: { onDrop: (payload: DropPayload) => void; onHover: (over: boolean) => void },
): () => void {
  const zone: Zone = { el, ...handlers };
  zones.add(zone);
  listenForNativeDrags();

  const dragover = (e: DragEvent) => {
    if (!e.dataTransfer?.types.includes("text/plain")) return;
    // Without this the browser refuses the drop and animates it back.
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
    setHover(zone);
  };

  const dragleave = (e: DragEvent) => {
    // Moving between the pane's children fires dragleave on the way out of each
    // one; only the exit that lands outside the pane counts. The `hovered` check
    // stops a late leave from the pane you came from clearing the highlight the
    // pane you just entered has already claimed.
    if (hovered === zone && !el.contains(e.relatedTarget as Node | null)) setHover(null);
  };

  const drop = (e: DragEvent) => {
    const text = e.dataTransfer?.getData("text/plain") ?? "";
    setHover(null);
    if (!text) return;
    e.preventDefault();
    zone.onDrop({ text });
  };

  el.addEventListener("dragover", dragover);
  el.addEventListener("dragleave", dragleave);
  el.addEventListener("drop", drop);

  return () => {
    el.removeEventListener("dragover", dragover);
    el.removeEventListener("dragleave", dragleave);
    el.removeEventListener("drop", drop);
    if (hovered === zone) setHover(null);
    zones.delete(zone);
  };
}

// Anything outside this set could be split into separate words, or eaten, by a
// shell the agent hands the path to.
const SHELL_SAFE = /^[A-Za-z0-9_@%+=:,./~-]+$/;

function quote(path: string): string {
  return SHELL_SAFE.test(path) ? path : `'${path.replace(/'/g, "'\\''")}'`;
}

/**
 * Dropped paths as terminal input: absolute, quoted when they need it, and
 * space-separated — what a terminal types when you drop a file on it.
 */
export function pathsToInput(paths: string[]): string {
  const usable = paths
    // A control character in a filename is legal on Unix and would be read as a
    // keystroke here — a newline would submit the prompt mid-path.
    .map((path) => path.replace(/[\x00-\x1f\x7f]/g, ""))
    .filter(Boolean);
  // Trailing space so the next thing typed doesn't run into the path.
  return usable.length ? `${usable.map(quote).join(" ")} ` : "";
}

/** Dropped text as terminal input. */
export function textToInput(text: string): string {
  // Strip every control character except newline, so dragged text can't smuggle
  // escape sequences into the agent's terminal.
  const clean = text.replace(/\r\n?/g, "\n").replace(/[\x00-\x09\x0b-\x1f\x7f]/g, "");
  if (!clean.includes("\n")) return clean;
  // Multi-line text is a paste, not typing: bracket it so the agent's prompt
  // inserts it whole instead of submitting on the first newline.
  return `\x1b[200~${clean}\x1b[201~`;
}

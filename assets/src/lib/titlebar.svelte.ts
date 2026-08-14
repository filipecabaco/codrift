// Window chrome.
//
// macOS builds run with `titleBarStyle: "Overlay"` and `hiddenTitle` (see
// src-tauri/tauri.conf.json), which removes the separate native title bar and
// draws the traffic lights straight onto the page. That is what collapses the
// old two-bar stack — OS title bar above, app header below — into one slim row.
//
// The trade is that the buttons now float over our own content, so the header
// has to keep a gutter clear for them, and has to notice when they go away.

// Measured against the standard macOS cluster: three 12px buttons on a 20px
// pitch, the first one 20px in. 78 clears the last button with a gutter that
// reads as deliberate spacing rather than a gap.
const TRAFFIC_LIGHT_INSET = 78;

type TauriWindow = { getCurrentWindow: () => { isFullscreen: () => Promise<boolean> } };
type TauriEvent = { listen: (event: string, handler: () => void) => Promise<unknown> };
type TauriGlobal = { window?: TauriWindow; event?: TauriEvent };

function tauri(): TauriGlobal | null {
  return (window as unknown as { __TAURI__?: TauriGlobal }).__TAURI__ ?? null;
}

/**
 * Is anything overlapping the top-left of the page?
 *
 * Only the macOS shell overlays. A plain browser tab (the UI is also served
 * straight from the sidecar on :43117) and the Windows and Linux builds all
 * keep a real title bar of their own, so there is nothing to pad around and no
 * region worth making draggable.
 */
export const overlayed = !!tauri()?.window && /Mac/i.test(navigator.userAgent);

export const titlebar = $state({ inset: overlayed ? TRAFFIC_LIGHT_INSET : 0 });

// Native fullscreen hides the traffic lights completely. Holding the gutter
// open would leave the wordmark indented against nothing.
async function sync(): Promise<void> {
  const win = tauri()?.window?.getCurrentWindow();
  if (!win) return;
  try {
    titlebar.inset = (await win.isFullscreen()) ? 0 : TRAFFIC_LIGHT_INSET;
  } catch {
    /* window API refused — better a stale gutter than a broken header */
  }
}

/** Starts tracking the traffic lights. No-op anywhere they don't exist. */
export function initTitlebar(): void {
  if (!overlayed) return;
  void sync();
  // Tauri has no fullscreen event; entering and leaving both resize the window,
  // and `sync` is a cheap getter, so resize is the signal.
  void tauri()?.event?.listen("tauri://resize", sync);
}

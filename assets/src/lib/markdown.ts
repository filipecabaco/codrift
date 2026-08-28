import { Marked } from "marked";
import { fileUrl } from "$lib/api";

/**
 * Markdown parsing for documents that live on disk, with their images resolved.
 *
 * A README's images are almost always written relative to the file
 * (`docs/images/x.png`), and for a long time nothing served those: every one of
 * them 404'd and drew a broken-image icon through the middle of the prose, so
 * the renderer replaced them all with a named placeholder. `GET /api/file` now
 * serves anything inside the initiative's own directories, so a relative image
 * becomes a real `<img>` — the screenshots an agent drops into a context folder
 * included.
 *
 * Remote images (`https://…` badges) stay placeholders on purpose. They are the
 * one thing on the page that would reach off the machine, and a README is not a
 * good enough reason to make the app fetch from a third party.
 */
export function markdownFor(initiativeId: string, baseDir: string | null): Marked {
  // A fresh instance rather than `marked.use`, which mutates the shared parser
  // every other caller renders with — and each document needs its *own* base
  // directory to resolve against.
  return new Marked({
    renderer: {
      image({ href, text }) {
        const resolved = baseDir && localImage(href) ? join(baseDir, href) : null;
        const alt = escapeHtml(text || "");

        if (resolved) {
          return `<img src="${escapeHtml(fileUrl(initiativeId, resolved))}" alt="${alt}" loading="lazy" />`;
        }

        // The renderer is handed *raw* alt text, so it is escaped before it
        // reaches {@html}.
        const label = text || href.split("/").pop() || "image";
        return `<span class="rounded border border-border px-1.5 py-px text-[11px] text-muted">🖼 ${escapeHtml(label)}</span>`;
      },
    },
  });
}

/** Escapes text destined for an HTML attribute or text node in a {@html} block. */
export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// Anything with a scheme (http:, data:, tauri:) or a protocol-relative prefix
// is somebody else's to serve. A leading `/` is rejected too: an absolute host
// path would resolve outside the initiative and the server would refuse it.
function localImage(href: string): boolean {
  return href !== "" && !/^([a-z][a-z0-9+.-]*:|\/\/|\/)/i.test(href);
}

// `path.join` for the browser: strips `./`, resolves `../`, and drops any
// `?query#fragment` the author appended.
function join(base: string, href: string): string {
  const segments = base.split("/");
  for (const part of href.replace(/[?#].*$/, "").split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") segments.pop();
    else segments.push(part);
  }
  return segments.join("/");
}

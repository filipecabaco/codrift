// One place that decides what each thing in Codrift *looks* like, so the
// sidebar, the overview and the tree can't drift apart.
//
// Heroicons are stroked with `currentColor`, which is the whole point here: a
// theme change re-colours every icon for free, no per-theme asset set.
import {
  CircleStack,
  CommandLine,
  CpuChip,
  Document,
  DocumentText,
  Folder,
  FolderOpen,
  RectangleStack,
  Share,
} from "@steeze-ui/heroicons";
import type { IconSource } from "@steeze-ui/svelte-icon";

/** An initiative: the stack of work a set of directories belongs to. */
export const InitiativeIcon: IconSource = RectangleStack;

/** The memory store. */
export const MemoryIcon: IconSource = CircleStack;

/** orchestration.md — the plan that coordinates several agents. */
export const OrchestrationIcon: IconSource = Share;

/** initiative.md and any other prose in the initiative folder. */
export const DocIcon: IconSource = DocumentText;

/** A non-prose file in the initiative folder (scripts, configs). */
export const FileIcon: IconSource = Document;

export const FolderIcon: IconSource = Folder;
export const FolderOpenIcon: IconSource = FolderOpen;

/**
 * A directory under version control. Heroicons has no git glyph, so this is the
 * branch mark hand-authored in the same data shape — stroked in `currentColor`
 * like the rest, so it themes identically. A different *silhouette* from the
 * plain folder, not a badge on top of one: at 14px a badge is a smudge.
 */
export const RepoIcon: IconSource = {
  default: {
    a: {
      fill: "none",
      viewBox: "0 0 24 24",
      "stroke-width": "1.5",
      stroke: "currentColor",
      "aria-hidden": "true",
    },
    path: [
      { "stroke-linecap": "round", d: "M6 6v12" },
      { d: "M6 3a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3Z" },
      { d: "M6 18a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3Z" },
      { d: "M18 6a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3Z" },
      {
        "stroke-linecap": "round",
        "stroke-linejoin": "round",
        d: "M18 9v2.25A3.75 3.75 0 0 1 14.25 15H9.75A3.75 3.75 0 0 0 6 18.75",
      },
    ],
  },
};

/** Project directories: a repo reads differently from a plain folder. */
export function dirIcon(isGit: boolean | undefined): IconSource {
  return isGit ? RepoIcon : FolderIcon;
}

/** A shell agent (the embedded terminal) vs an AI coding agent. */
export const TerminalAgentIcon: IconSource = CommandLine;
export const AgentIcon: IconSource = CpuChip;

const PROSE = new Set(["md", "markdown", "txt", "rst", "adoc"]);

/** Picks the icon for a file inside an initiative folder by what it *is*. */
export function contextFileIcon(relativePath: string): IconSource {
  const name = relativePath.split("/").pop() ?? relativePath;
  if (name === "orchestration.md") return OrchestrationIcon;
  const ext = name.includes(".") ? name.split(".").pop()!.toLowerCase() : "";
  return PROSE.has(ext) ? DocIcon : FileIcon;
}

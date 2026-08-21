# Product Marketing Context

**Document version:** v4
**Last updated:** 2026-08-21

## Product Overview

**One-liner:** Run many AI coding agents at once without losing track of one.

**What it does:** Codrift is a desktop control surface for running Claude Code,
Codex, Opencode, Gemini, Copilot, Cursor and raw shells side by side, against
every repo in a piece of work at the same time. You group directories into
*initiatives*, launch an agent per directory into its own git worktree, watch
each one live in a real embedded terminal, review one combined diff across all
of it, and let the agents share a memory store. An MCP server lets one agent
plan and drive the others.

**Product category:** Multi-agent coding control surface. The shelf is new and
unnamed, which is a positioning problem as much as an opportunity — people do
not yet search for this by category. They arrive from an adjacent shelf:
"running multiple Claude Code instances", "managing parallel AI agents", or
from terminal multiplexing.

**Product type:** Open-source desktop application (Tauri shell + Svelte UI +
Elixir/Francis backend). macOS and Linux. Distributed via Homebrew cask,
`install.sh`, and GitHub Releases. Currently v0.1.x.

**Business model:** Free and open source today. Planned: self-hosting stays
free (same binary, `CODRIFT_MODE=hosted`); a managed hosted tier is the first
paid product, provisionally ~$49/mo with bring-your-own model keys. See
`docs/hosting.md` and `docs/go-to-market.md`.

## Target Audience

**Target companies:** Not company-led today. Individual developers and small
teams; agencies and consultancies running work across several repos. Company
size is not the segmenting variable — *number of agents you run at once* is.

**Decision-makers:** The developer themselves. This is a bottom-up,
practitioner-chosen tool with no procurement step. That changes at the hosted
team stage, not before.

**Primary use case:** One piece of work that spans several repositories, with
an agent working in each, where the human is supervising rather than typing.

**Jobs to be done:**
- Run more agents than I can watch, and know at a glance which one needs me.
- Let agents work without them touching my main checkout.
- Stop re-typing the same project context into every new agent session.

**Use cases:**
- A feature that crosses API, edge service and dashboard: one agent per repo,
  one diff at the end.
- A conductor agent that plans work and spawns sub-agents across directories.
- A second opinion: two different adapters on the same directory.
- A long mechanical migration fanned out across many repos.

## Personas

Single-persona for the free desktop product; the hosted tier introduces a
second buyer whose economics are different enough to change the ordering.

| Persona | Cares about | Challenge | Value we promise |
|---|---|---|---|
| **Practitioner** (senior/staff eng, indie dev) | Throughput without losing control | Four agents produce more output than they can read | Know which one is stuck, in a glance |
| **Security-minded dev** (hosted) | What runs on their machine | Won't give an agent a shell on their laptop | Agents run in an isolated VM, not on your machine |
| **Team lead** (future, Stage B) | Agents on org repos without laptop-shaped risk | No way to standardise or contain it | Managed workspaces, per-user isolation |

**Reach order and revenue order differ.** The practitioner leads on reach — they
are the only audience we can currently address. The security-minded dev leads on
*revenue*, because the practitioner already has the product free and the
security-minded dev has no free alternative at all. Do not narrow awareness work
to match the revenue ordering.

## Problems & Pain Points

**Core problem:** Attention routing, not generation. In the product's own
words: *"Output stopped being scarce. Your attention didn't."* Once you run
four agents, the job stops being typing and becomes finding the one that is
actually stuck.

**Why alternatives fall short:**
- **Terminal tabs / tmux:** a tab title carries the repo name, never the fact
  that an agent stopped ten minutes ago to ask a question. So you check all
  four, every time.
- **Wrapper UIs:** they paraphrase the agent instead of showing it. You lose
  the agent's own interface, and with it your ability to trust what you see.
- **Single-agent IDE integrations:** built for one agent in one repo. No
  fan-out, no cross-repo diff, no shared context.
- **Everything is single-checkout:** two agents in one working tree collide.

**What it costs them:** Polling every agent on a loop; context re-typed per
session; work lost to agents overwriting each other; the slowest agent setting
the pace because nobody noticed it was blocked.

**Emotional tension:** The background hum that something is waiting on you and
you don't know which thing. Supervising without visibility is more tiring than
doing the work.

## Competitive Landscape

**For the paid tier, the alternative is our own free product.** The single most
disciplining fact in this document. Someone considering hosted Codrift would
not fall back to a competitor if it vanished — they would install the desktop
app, for nothing, today. Any hosted pitch that does not answer *why not just
install it?* is a benefit list, not a position. The only answer that survives
intact: for some buyers, installing it was never on the table.

**Direct:** Profiled in `competitor-profiles/`. Verified 2026-08-21 from
primary sources.

| Competitor | Shape | Why it's a threat |
|---|---|---|
| **Conductor** | macOS app + cloud, proprietary, free / $50 / $60-seat | Ships the hosted product we are planning, at our price, with our drafted tagline. Real-time collaboration. Vercel-backed. |
| **Nimbalyst** (ex-Crystal) | Desktop + iOS, MIT, free with no limits | Beats us on platform reach (Windows, iOS) at the same price and licence |
| **Claude Squad** | Terminal TUI over tmux, open source, 8.3k stars | The lean answer for people who never wanted a GUI |
| **Vibe Kanban** | Web kanban, Apache-2.0, 27.9k stars, **sunsetting** | Proves demand; its sunset questions monetisation |

**The platform is the real direct competitor.** Claude Code now ships
`claude --worktree <name>` for isolated parallel sessions, and a background-agent
view to "monitor parallel sessions from one screen" (Anthropic docs, fetched
2026-08-21). A branch per agent and one screen for many agents are **table
stakes, not differentiators**. Never lead with either.

**For the paid tier, the alternative is also our own free product.** Someone
considering hosted Codrift would not only weigh Conductor — they would install
our desktop app, for nothing, today. Any hosted pitch that does not answer *why
not just install it?* is a benefit list, not a position.

**Secondary:** tmux/terminal tabs plus N agent processes. Free, already
installed, infinitely flexible — and the thing most of our audience is doing
right now. It falls short on agent state and on anything cross-repo. Note that
Claude Squad has 8.3k stars for productising almost exactly this, so "just use
tmux" is a position with real adherents.

**Indirect:**
- *Run one agent and go slower.* Falls short only once you believe parallelism
  is worth managing — which is a belief we have to create, not assume.
- *Fully async cloud agents that own a whole task.* Different bet: they remove
  the human from the loop; Codrift keeps the human supervising. Not a
  substitute, and worth saying so plainly rather than competing on their terms.

## Differentiation

**The lead position — any agent, across any number of repos, in one place.**
Two capabilities that are individually matchable and jointly unheld:

- **Vendor-neutral by construction.** Seven adapters — Claude Code, Codex,
  Opencode, Gemini, Copilot, Cursor and a raw `$SHELL` — behind one launcher and
  one keyboard. Conductor has three; the native CLI has one.
- **The initiative is the unit of work, and it is multi-repo.** Several
  directories, one branch name, one combined diff, one shared memory. Every
  competitor profiled organises around a single task, session or repo.

Neither half is unique on its own: Vibe Kanban shipped ten adapters, Claude
Squad does four-plus. **The pairing is.** Conductor holds neither fully — three
vendors, single-repo workspaces. State them together; ranked separately they
both read as feature lists.

**Why vendor neutrality is load-bearing, not merely broad.** The largest threat
in `competitor-profiles/` is the platform absorbing the category: Claude Code
now ships native worktrees and a parallel-session view. A product built on one
vendor's CLI has no answer to that vendor shipping the same thing — Conductor
loses a third of its surface and its users gain a reason to leave. A product
where every CLI is an adapter absorbs the platform's improvements *inside*
itself rather than competing with them. Multi-provider is the hedge against the
single biggest risk to this business.

It also buys three things a single-vendor product cannot:
- **A second opinion** — two different adapters on the same directory.
- **The right agent per repo**, rather than the same one everywhere, as model
  quality and pricing keep moving.
- **The raw shell as a first-class agent**, which is what makes the human
  handoff (`open_terminal`) possible at all — the most remarkable beat in the
  demo, and a direct consequence of the adapter model.

**Also defensible:**
- **Open source *and* self-hostable hosting.** Conductor Cloud is proprietary.
  A hosted product whose image you can run in your own VPC is the one thing the
  better-resourced competitor structurally cannot follow.

**True, but shared with the field:**
- **Real PTYs, byte-for-byte** — a genuine quality difference against wrappers,
  but hard for a prospect to evaluate before trying it.
- **Agent state is first-class** (`running` / `needs input` / `idle` /
  `stopped`, rolled up as "3 waiting"). Conductor says "see at a glance what
  they're working on"; Claude Code ships a background-agent view. Ours is better
  articulated, not unique.
- **A worktree per directory** — now native in Claude Code. Table stakes.
- **Shared memory + MCP conductor** — overlapped by Munder Difflin.
- **One binary, no runtime.** Nimbalyst is also free, MIT and on more platforms.

**How we do it differently:** Everyone else is trying to make agents produce
more. Codrift assumes they already produce too much, and optimises the human's
attention instead.

**Why that's better:** It is the only bottleneck that scales with agent count.

**Why customers choose us:** They already ran three agents in three tabs and
found it unmanageable — and their work spans more than one repository, which is
where every alternative stops.

**Deliberate non-goals, stated as choices rather than gaps:** real-time
collaboration (Conductor sells it; our model is one supervisor per workspace)
and Windows (Nimbalyst has it; we do not).

## Objections

| Objection | Response |
|---|---|
| "Why not just tmux?" | tmux moves panes; it cannot tell you an agent is blocked. Codrift is the state layer, not the layout layer — and it uses real PTYs, so tmux habits still work inside it. |
| "Not code-signed or notarized" | True today. The Homebrew cask strips quarantine; source is public and buildable. **This is a launch dependency, not a caveat** — it is a distribution barrier, a signal of provisionality at the exact moment we ask for trust in software that runs shell commands, and the top objection of the segment the paid tier is built for. It blocks that segment twice: they will not install unsigned software, and they are the ones being asked to pay for isolation. |
| "macOS and Linux only" | No Windows build today. WSL is the honest interim answer. |
| "I don't want an agent with a shell on my machine" | Correct instinct, and the reason the hosted tier exists: kernel-isolated per-user VM. Locally, worktrees keep it off your main checkout. |
| "It's v0.1 — is this going to exist next year?" | Open source, so it survives us; releases are frequent and public. Do not over-promise a roadmap. |

**Anti-persona:** Someone running exactly one agent in one repo. The entire
value proposition is fan-out; a single-agent user should keep using their CLI
directly, and telling them so builds more credibility than converting them.

## Switching Dynamics

**Push:** Checking four terminal tabs on a loop. Discovering an agent has been
blocked for twenty minutes. Two agents fighting over one checkout. Pasting the
same project context into a fifth session.

**Pull:** One window where every agent is visible and the blocked one announces
itself. A branch per agent. One diff across all repos.

**Habit:** tmux and terminal tabs are muscle memory, free, and already
configured. This is the real competitor.

**Anxiety:** "Another layer between me and my agent." Answered directly by the
real-PTY design — there is no layer, and the product should keep saying so.

## Customer Language

**How they describe the problem:**
- "I have four Claude windows open and I've lost track of what each one is doing"
- "I keep checking every tab to see if one's waiting on me"
- "I don't want them all editing the same checkout"

*(Directional, inferred from the product's own framing — not yet verified
against real customer interviews. Replace with verbatim quotes as soon as the
private beta produces them; this is the highest-value gap in this document.)*

**How they describe us:** Unknown. No testimonials yet.

**Words to use:** agent, initiative, worktree, terminal, pane, adapter,
conductor, waiting, blocked, fan out, one diff, byte-for-byte, supervise.

**Words to avoid:** *AI-powered* (they are the AI users, not the audience for
that word); *seamless*, *effortless*, *revolutionary*; *wrapper*; *copilot* as
a generic noun (it is an adapter name); *autonomous* (we deliberately keep the
human in the loop); *10x*.

**Glossary:**
| Term | Meaning |
|---|---|
| Initiative | A named piece of work grouping several directories, with its own context folder, memory and branch |
| Adapter | An agent CLI integration (claude, codex, opencode, gemini, copilot, cursor, terminal) |
| Conductor | An agent given the MCP server that plans and drives sub-agents |
| Worktree | The per-directory git branch an agent works in |
| Pane | One half of a split content area; holds an agent, a diff or a file tree |
| Memory | Per-initiative FTS5 store shared by all agents in that initiative |

## Brand Voice

**Tone:** Dry, precise, unhyped. Makes a specific claim and then substantiates
it in the next sentence. Never exclamatory.

**Style:** Second person, present tense, concrete nouns and real numbers ("Six
agents. Six branches."). Short declaratives next to one long explanatory
sentence. Comfortable naming what the product does *not* do — the existing copy
does this repeatedly and it is a large part of why it reads as credible.

**Personality:** Precise, opinionated, concrete, unhurried, honest about
limits.

## Proof Points

**Metrics:** Seven adapters. 66 themes. One binary, no runtime. Real PTY per
agent. Sessions resume across restarts. MCP server over SSE. Combined diff
across every directory.

*(Adoption metrics — installs, active users, retention — are unmeasured. This
is a gap: no owned audience and no analytics means every launch decision is
currently made blind. Mental and physical availability are both near zero —
unmeasured reach, an unsigned binary, no Windows build — and at this stage that
constraint outranks message optimisation. Instrument first.)*

**Customers:** None nameable yet.

**Testimonials:** None yet. Collecting two or three from the private beta is
the cheapest credibility available and should be an explicit beta goal.

**Value themes:**
| Theme | Proof |
|---|---|
| Know which agent needs you | Per-agent state; "3 waiting" rollup on the initiative row |
| Agents never collide | A git worktree and branch per directory |
| See the agent, not a wrapper | Real PTY, byte-for-byte terminal rendering |
| Say it once | Per-initiative context folder + shared FTS5 memory |
| Orchestration without glue code | MCP server; the conductor is just an agent with tools |
| Your work survives restarts | Session persistence, durable transcripts, scrollback replay |

## Goals

**Business goal:** Establish Codrift as the default surface for running many
coding agents, then convert a slice of that install base to a paid hosted tier.

**Conversion action:** Today — run the install command (or `brew install
--cask codrift`). Hosted — start a workspace.

**Current metrics:** Unknown. No email list, no analytics, install base
unmeasured. Building somewhere for interest to land is the first GTM task.

## Changelog

*Newest first. One line per revision: what changed and why.*
- v4 (2026-08-21) — Promoted vendor neutrality to the lead position, paired with the multi-repo initiative: neither is unique alone, the combination is, and multi-provider is the structural hedge against the platform-absorption threat found in v3.
- v3 (2026-08-21) — Filled the named-competitor gap from primary-source research (`competitor-profiles/`). Two findings forced a repositioning: Claude Code now ships native worktrees and a parallel-session view, making both table stakes; and Conductor already sells the hosted tier at $50/mo using the tagline we had drafted. Differentiators reordered by defensibility — the multi-repo initiative is now the lead, parallelism is demoted.
- v2 (2026-08-21) — Named our own free desktop app as the paid tier's competitive alternative, and split reach ordering from revenue ordering as a result; promoted notarization from caveat to launch dependency; noted availability outranks messaging at this stage. From a positioning review.
- v1 (2026-08-21) — Initial context, drafted from the landing page, README and codebase alongside the cloud-hosting and go-to-market plans.

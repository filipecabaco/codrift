# Conductor — Competitor Profile

**URL**: https://conductor.build
**Generated**: 2026-08-21
**Depth**: Quick scan (no SEO/review data — Firecrawl and DataForSEO not connected)

---

## At a Glance

| Metric | Value |
|---|---|
| Tagline | "Run a team of coding agents in the cloud" |
| Product headline | "Run parallel Claude Code, Codex, and Cursor agents in isolated workspaces on your Mac." |
| Platform | macOS only (desktop); cloud tier is browser-reachable |
| Agents supported | Claude Code, Codex, Cursor ("model agnostic") |
| Pricing | Free · Pro $50/mo · Teams $60/user/mo · Enterprise custom |
| Cloud infra | Vercel Sandbox, isolated microVMs, 8 vCPU / 16 GB, Amazon Linux 2023 |
| Domain rank / traffic | Not available (no DataForSEO) |

---

## Positioning & Messaging

**Primary value proposition:** Create parallel Claude Code, Codex and Cursor
agents in isolated workspaces; see at a glance what they're working on, then
review and merge their changes.

**Positioning angle:** Polished, native-Mac, team-capable. Started local, moved
to the cloud — the same trajectory `hosting.md` describes for Codrift, executed
first.

**Key messaging themes:**
- Parallel agents in isolated workspaces (homepage)
- **"See at a glance what they're working on"** (homepage) — near-identical to
  Codrift's attention-routing claim
- **"Close the laptop, and have the agents keep working"** (Vercel customer
  story) — the exact phrasing considered for Codrift's hosted lead claim
- Multiplayer: share a workspace link, see who is active, prompt agents together
  in real time (docs)

---

## Product & Features

### Core capabilities
- Parallel agents, one isolated workspace per task/repository
- Cloud Workspaces: agents spin up on a remote server, "run for hours"
- Side-panel diff review of remote agents' changes
- Real-time collaboration on a shared workspace link (⌘⇧C)
- Repos and dependencies pre-installed in the sandbox image

### Notable differentiators
- **Collaboration.** Multiple humans in one workspace, prompting together.
  Codrift explicitly puts this out of scope.
- **Vercel partnership.** Cloud Workspaces built on Vercel Sandbox, with a
  published joint customer story — distribution and credibility Codrift has no
  equivalent of.

### Product direction signals
Local → cloud → multiplayer. Covered by The New Stack as part of a broader
"rush toward remote coding agents", i.e. a contested category, not an empty one.

---

## Pricing

| Tier | Price | Key inclusions |
|---|---|---|
| Free | $0 | Parallel coding agents, local workspaces on Mac |
| Pro | $50/mo | Adds cloud workspaces and multiplayer |
| Teams | $60/user/mo | Live team collaboration, admin tools |
| Enterprise | Custom | Advanced security, SSO, dedicated support |

**Notable:** The free tier is the *local* product and the paid tier is the
*cloud* product — precisely the free-vs-paid boundary Codrift's plan proposes,
already validated in market at $50 against Codrift's provisional $49.

---

## Strengths & Weaknesses

### Strengths
- Ships the hosted product today; Codrift's Stage B is a plan
- Price point already tested at $50/mo
- Multiplayer, which Codrift has ruled out by architecture
- Vercel relationship for infrastructure and reach

### Weaknesses
- **macOS only** — no Linux desktop, no Windows
- Three agent CLIs vs Codrift's seven; no raw-shell adapter
- Proprietary; no self-host path, so no answer for buyers who need the code in
  their own VPC
- Workspace is task/repo-shaped; no evidence of a multi-repo grouping primitive
  equivalent to initiatives

---

## Competitive Implications for Codrift

**Where they're strong vs us:** Shipped hosted product, collaboration,
distribution, and a Mac-native polish reputation.

**Where we're strong vs them:** Linux; seven adapters including a raw shell;
open source and self-hostable; real PTY rendering; the initiative as a
multi-repo unit; shared memory plus an MCP conductor.

**Opportunities:** Self-host and open source are the axes they structurally
cannot follow us on. Linux and multi-repo are unserved by them.

**Threats:** They own the phrase and the price point Codrift's plan was built
around. Entering as an undifferentiated second mover at the same price into
their category is the failure mode to avoid.

---

## Raw Data Sources

- conductor.build homepage and /pricing — fetched 2026-08-21
- Vercel customer story, "How Conductor moved parallel coding agents from the laptop to the cloud with Vercel Sandbox" — 2026-08-21
- The New Stack, "Cloud code: Conductor joins the rush toward remote coding agents" — 2026-08-21
- conductor.build/docs/cloud/working-with-cloud-workspaces — 2026-08-21

# Cloud hosting: go-to-market and showcase

The engineering plan is [`hosting.md`](hosting.md). This is the same two stages
read from the outside: what changes about the story, who it is for, what we
show people, and in what order we tell them.

Nothing here is a campaign. It is the smallest set of decisions that has to be
made *before* Stage A ships, because they change what gets built — a demo you
cannot record is a feature you built wrong.

## The positioning problem, stated honestly

The site today sells four things, and hosting contradicts two of them:

| Current claim | Hosted |
|---|---|
| Run many AI coding agents at once | unchanged — this is still the product |
| Six agents. Six branches. Your checkout untouched. | unchanged |
| **One binary. No runtime to install.** | there is no binary; there is a URL |
| Every agent in its own terminal, on screen at once | unchanged, but in a browser tab |

So "hosted Codrift" cannot be sold as *more of the same*. If we lead with
convenience — "now in the cloud!" — we are competing with our own install
command, which is genuinely better for the local case and is the thing people
already like.

**The competitive alternative is our own free product.** This is the fact that
disciplines everything else. If hosted Codrift did not exist, the buyer would
not fall back to tmux — they would install the desktop app, for nothing, today.
So a hosted benefit is not enough; the position has to answer *why not just
install it?*, and only one answer survives that question intact: **for some
people, installing it was never on the table.**

That gives two entry points into one positioning, not two positionings:

- **To the install base (product-aware):** hosted is Codrift that keeps
  running — the hours you are not watching, not the moment you are.
- **To everyone who refused the local product (problem-aware at best):** the
  agents do not run on your machine. This is not a nicer version of something
  they declined — it is the only version that exists for them, which is the one
  condition under which a paid tier reliably beats a free one.

> **"Close the laptop. The agents keep working." is retired.** Competitor
> research (`competitor-profiles/_summary.md`) found Conductor already shipping
> the hosted product, at $50/mo, described in Vercel's own customer story as
> letting developers *"run a fleet of coding agents in parallel, close the
> laptop, and have the agents keep working."* The phrase is a competitor's
> shipped positioning, not an available one. The demo beat survives — the
> physical gesture is still the clearest way to *show* continuity — but it
> cannot be the words.

## What the competitive research changed

Read `competitor-profiles/_summary.md` before this document; two findings there
overturn assumptions made above and below.

1. **Parallelism is table stakes.** Claude Code ships `claude --worktree` for
   isolated parallel sessions and a background-agent view to watch them from one
   screen. A branch per agent and one screen for many agents are now first-party
   and free. Nothing in a headline should lead with either.
2. **The hosted category is occupied.** Conductor sells cloud workspaces on
   Vercel Sandbox microVMs at $50/mo with real-time collaboration. Stage B is
   not the creation of a market, it is late entry into someone else's — at their
   price, and it must therefore differ on something other than existing.

What survives as genuinely ours is one position with two halves: **any agent,
across any number of repos, in one place.** Seven adapters — Claude Code,
Codex, Opencode, Gemini, Copilot, Cursor and a raw shell — against an initiative
that groups several directories under one branch, one diff and one memory.
Conductor holds neither half fully: three vendors, single-repo workspaces. The
native CLI holds neither at all.

**Vendor neutrality is the direct answer to finding 1.** If the platform keeps
absorbing the category, a product built on one vendor's CLI has no reply —
Conductor loses a third of its surface and its users gain a reason to leave.
A product where every CLI is an adapter takes the platform's improvements
*inside* itself instead of competing with them. That makes multi-provider the
hedge against the biggest risk to the business, not just a longer feature list.
It is also why a raw shell can be an agent at all, which is what makes the
handoff demo possible.

Be honest about the limit: breadth alone is matchable. Vibe Kanban shipped ten
adapters. The pairing with multi-repo is what nobody holds, so the two are
always stated together.

Third, and separately defensible: **open source with self-hostable hosting**
(Conductor Cloud is proprietary), which is the axis the better-resourced
competitor cannot follow.

That reorders the pitch. Lead on *whatever agent, across the repos the work
actually touches* — not on *running agents in parallel*.

## Before any of this: availability

Three things below outrank every word of copy in this document, and none of
them are marketing work. They are listed first because message optimisation
against near-zero availability is real effort aimed at the wrong constraint.

1. **Sign and notarize the binary.** Today the install path includes an
   operating-system warning the user has to be talked through. That is a
   distribution barrier, and it is also a *signal*: it says provisional and
   cheap at exactly the moment we ask someone to trust software that runs
   shell commands — and then to pay monthly to have that code isolated. It is
   simultaneously the top objection blocking the segment the paid tier is aimed
   at. **Treat it as a launch dependency, not a caveat.**
2. **Instrument installs and retention.** Every sequencing decision here
   currently assumes the install base is small. It is unmeasured. If it is not
   small, the beta should be wider and sooner.
3. **Build one owned channel.** No email list means no way to deliver any of
   this. See the sequencing section: this is the first task, not a later one.

## The three things hosted actually adds

Each of these is a property of the architecture, not a slogan — which is what
makes them defensible in a demo.

1. **Agents outlive your session.** A local agent dies with the machine that
   spawned it. A hosted workspace is a supervised BEAM with long-lived PTYs on
   a persistent volume; a six-agent fan-out runs for an hour while you are in a
   meeting, and the transcripts are there when you come back
   (`.agent-logs`, scrollback replay, session resume).
2. **Arbitrary code stops running on your laptop.** This is the quiet one, and
   for some buyers it is the whole purchase. Agents execute shell commands. The
   hosted answer is a per-user micro-VM with an egress policy — kernel-level
   isolation, which no local install can offer. "Your checkout untouched"
   becomes "your machine untouched".
3. **Any device is a full workstation.** The SPA is origin-agnostic already
   (`stream.ts` builds its WebSocket from `location.host`). A tablet on a train
   is the same six terminals. Nothing is ported; it already works.

Note what is *not* on this list: collaboration. The model is one supervisor per
workspace and `hosting.md` puts multi-user explicitly out of scope. We should
not imply a team product we have not built.

## Who this is for

Two different orderings, and conflating them is how the plan goes wrong.

**For reach, the install base comes first** — they are the only people we can
currently talk to at all. **For revenue, they come second**, because they
already have the thing for free and a benefit is a weak reason to start paying.

**Paid-tier segment 1 — the developer who will not run agents on their
machine.** Opinions about `curl | sh`, about credentials on disk, about an
agent with a shell. Today they are a non-buyer of the desktop app entirely, so
there is no free alternative competing with the paid one — the only condition
under which this reliably converts. The isolation story *is* the product for
them. Note the dependency: the same person will not install an unsigned
binary either, so notarization gates this segment twice over.

**Paid-tier segment 2 — the person already running Codrift locally and hitting
the ceiling.** They have felt agents die when they closed the lid. Zero
education needed and the pitch is one sentence, which is why they lead on
reach. But they are also the hardest to charge, because the free alternative is
genuinely good and it is ours.

**Paid-tier segment 3 — the team lead** who wants agents running against the
org's repos without handing everyone a laptop-shaped security problem. Real
budget, real procurement, and Stage B territory — VPC/BYOC questions arrive
with them (`hosting.md` names Northflank as that answer). Do not chase before
Stage B; do listen when they self-identify, because they set the price ceiling.

**A fourth alternative now sits alongside these: Nimbalyst.** Free, MIT, no
feature limits, and shipping on Windows and iOS as well as macOS and Linux.
"Free and open source" therefore is not a differentiator for us against it —
only self-hostable *hosting* is. Anyone comparing on price and platform reach
should be expected to land there.

**Do not narrow the top of the funnel to match this.** Segment ordering governs
who the *paid* pitch addresses, not who we reach. Awareness work should go to
everyone who runs a coding agent, including light and occasional users who will
never be anybody's tribe — excluding category buyers at our size is self-harm.

## The showcase

Codrift's advantage is that it is *legible on screen*. Six terminals, each
visibly doing different work, is a screenshot that explains itself — most
agent products have to be narrated. Lead with motion, not architecture.

**The demo, in order.** Each beat earns the next; total under three minutes.

1. **Start from a URL, not an install.** A browser tab, already logged in. The
   contrast with every other dev-tool demo is the point.
2. **Fan out.** One initiative, several directories, an agent per directory.
   The screen fills with terminals doing genuinely different things. This is
   the money shot and it should arrive within thirty seconds.
3. **The handoff.** An agent hits something it is not allowed to do and opens a
   terminal for you, with the command drafted at the prompt, unexecuted. You
   read it and press Return. (`open_terminal` — shipped.)

   This is the beat worth remarking on, which is why it moved up. "Cloud" is
   the expected move and nobody repeats it at lunch; an agent that *stops and
   hands you the keyboard* is a story someone tells. It also inverts the
   sentence this whole category struggles with — "an AI that commits code" —
   by showing the product visibly asking permission. We get it on film for
   free, because it is a real feature rather than a staged one.
4. **Close the laptop.** Literally. Reopen on a phone or a second machine, same
   workspace, agents further along than you left them. The claim demoted from
   the headline lives here instead, because its force is the physical gesture,
   not the sentence — and it is the one moment a competitor's screen recording
   cannot fake.
5. **The diff.** Combined diff across every directory the agents touched. Ends
   the demo on the artifact, not the machinery.

**For a cold audience, lead with mechanism rather than claim.** Every claim
about agents writing code has been made to exhaustion, so the differentiator
that still lands is *how it works*: real PTYs rendering byte-for-byte, a branch
per agent, a supervised process tree that outlives your session. "Close the
laptop" assumes someone already accepts the premise of supervising four agents;
mechanism does not.

**Assets, cheapest first.** A 30-second silent loop of beat 2 (fan-out) for
social and the landing page — it needs no audio and reads at any size. Then the
three-minute walkthrough. A screenshot of the SPA in a plain browser tab, which
is doing double duty as proof it is not a desktop mock. Interactive demos and
onboarding tours are Stage B work; they need a product people can sign into.

## Proof points

Marketing claims we can substantiate from the codebase, which matters because
this audience checks.

- **Open source, self-hostable, same binary.** Stage A is `CODRIFT_MODE=hosted`
  on the artifact we already ship. The free path is real, not crippled — that
  is credibility with segment 2, who will read the source before they trust it.
- **Your keys, your accounts.** Launch profiles already inject per-agent
  credentials and config directories; model API keys are BYO. We are not
  reselling inference.
- **We do not own your identity.** Auth is Supabase; Codrift verifies JWTs and
  issues none. Fewer things for us to leak.
- **It resumes.** Session persistence, durable transcripts, scrollback replay.
  "Your work survives our restarts" is a claim with code behind it.

## Sequencing

Mapped onto the engineering stages, using owned channels as the destination for
everything. We have almost no owned audience today — no email list — so the
first job is not announcing, it is having somewhere for interest to land.

**Now, before Stage A ships.** Two things, in this order.

*Availability first.* Sign and notarize the binary, and instrument installs.
Neither is marketing work and both outrank everything after them — see the
section above. Notarization in particular is a launch dependency for the paid
tier, not a nice-to-have, because the segment it converts is the same segment
that refuses unsigned software.

*Then somewhere for interest to land.* The website is stateless by design and
must stay that way, so a waitlist backend is out; `hosting.md` W1.4 already
lands on a pinned GitHub Discussion plus a mailto. That is the right call —
zero infrastructure, real signal, and it sizes demand for Stage B before any
control-plane code exists. Every later beat needs a destination.

**Stage A — self-host, aimed at segments 1 and 2.** Not a launch moment; a
credibility moment. Ship the container image, the `/hosted` guide, and the
"Hosted" section on the landing page. Announce where the install base already
is — changelog, repo, whatever social presence exists — framed as *"you can now
run this on your own box"*, not as a product launch. No Product Hunt. Spending
the one-time PH card on a self-host guide would be a waste; save it for the
moment there is something to sign up for.

**Between the stages — the private beta.** Hand-run managed workspaces for a
handful of people from segment 1, provisioned by hand. This is Superhuman's
move and it works for the same reason: the operational cost is the research
budget. It answers what the cost model cannot — how many hours a day a
workspace is really active, which decides whether $49 has margin.

**Stage B — the actual launch.** Self-serve signup, `app.codrift.app`, billing.
This is where the full checklist applies: Product Hunt, the demo video, the
comparison pages, the onboarding sequence. It is also the first moment we can
honestly say "start a workspace" instead of "read a guide".

## Pricing narrative

The engineering plan puts infrastructure at roughly $18/user/month and
concludes $49 is the realistic entry point. Two things follow for marketing:

- **BYO model keys at launch**, stated plainly and early. Absorbing inference
  cost changes the business, not just the margin, and pricing pages that hide
  it get punished by exactly this audience.
- **$49 is now a me-too price.** Conductor's cloud tier is $50. Arriving at a
  dollar under, eighteen months later, with fewer features and no
  collaboration, is the weakest possible position. Either price clearly
  differently — cheaper because self-host is the default and hosting is a
  convenience, or higher because it is isolation you can audit and run
  yourself — or do not compete on this axis at all.
- **Idle-suspend is a pricing feature, not just an infra one.** It is the
  single biggest lever on the number, and it is also a nice thing to say out
  loud: you are not paying for a box that sits there. Whether we can say it
  depends on the unresolved Sprites question in `hosting.md` — if a workspace
  suspends mid-task, that sentence turns into a support burden instead.
- **Hold the number until the beta.** $49 is arithmetic from the cost model,
  and arithmetic is how every competitor arrives at the same price. The
  security-minded buyer is not purchasing compute — they are purchasing not
  having an agent loose on their laptop, and a price set from infrastructure
  cost can signal "hobby tool" to exactly the person most willing to pay. Test
  willingness to pay while the number is still easy to move.

Free tier: the self-host path *is* the free tier. Do not also build a hosted
free tier — every free workspace is a real micro-VM with a real disk, and the
unit economics do not survive it.

## The tripwire

One risk deserves separating from the unknowns below, because it is the only
one where an infrastructure decision silently destroys the positioning.

**Idle-suspend is the biggest lever on margin and the biggest threat to the
claim.** If a workspace suspends while an agent is mid-task, "it keeps
working" inverts into "it quietly stopped" — and a stalled agent nobody is
watching is a worse product than one that never promised to run unattended.
That is the same unresolved Fly Sprites question sitting in `hosting.md`
("does CPU activity inside the VM count as activity, or only inbound
requests?"), which means an open infra question is also the single largest
brand risk here. **Resolve it before the claim goes public**, and do not let
it be optimised away for cost after launch.

## What we do not know yet

Stated so nobody mistakes the confident tone above for evidence:

- **Audience size.** No email list, and the install base is unmeasured. Every
  sequencing decision above assumes it is small; if it is not, the private
  beta should be wider and sooner.
- **Whether isolation really outsells continuity.** The plan now assumes it
  does for the paid tier, on the reasoning that continuity competes with our
  own free product and isolation does not. That is an argument, not evidence.
  The private beta answers it and it is the single most valuable thing it
  produces.
- **Session shape.** Hours-per-day of active use is a marketing input (how
  strong is "close the laptop"?) as much as a cost input.
- **Whether anyone wants a team version badly enough to fund it.** Segment 3
  will ask. The honest answer today is no, and we should keep saying so until
  it changes.

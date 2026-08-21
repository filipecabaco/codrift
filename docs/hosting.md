# Cloud hosting plan

How Codrift goes from a loopback desktop sidecar to a remotely hosted service,
in two deliverable stages. The outside view of the same two stages —
positioning, who it is for, the demo, and launch sequencing — is
[`go-to-market.md`](go-to-market.md).

- **Stage A — remote single-user workspace.** One Codrift instance in a
  container on a machine the user controls, reached over TLS with real
  authentication. Single-user model unchanged. Independently shippable.
- **Stage B — multi-tenant service.** A thin control plane that provisions
  one Stage-A instance per user (isolated micro-VM + volume) and proxies
  HTTP/WS into it. Codrift itself stays single-tenant inside its container.

True in-process multi-tenancy (threading `user_id` through `Core`, the stores
and every path) is explicitly rejected: the work is large, and users' agents
run arbitrary code, so they must not share a kernel anyway. Isolation lives at
the infrastructure boundary, which is what keeps the Elixir changes small.

**Identity is Supabase Auth in both stages.** Codrift verifies JWTs and never
issues them, so there is no session store, no password handling and no login
UI to own — and Stage B inherits an account system instead of building one.
This is strictly about *who the user is*; the OAuth code Codrift runs as a
*client* against GitHub, Linear and GitLab for integrations stays ours, for
reasons set out in A5. The two are easy to conflate and cost very different
amounts.

## Why this is feasible

The product is already a headless server plus a dumb window:

- The backend is a Francis/Bandit app serving HTTP, WebSocket, SSE and the
  built SPA from `priv/static`. The Tauri shell (`src-tauri/`) only spawns the
  sidecar and points a webview at it — no product logic lives there.
- The SPA uses only relative URLs (`assets/src/lib/api.ts` → `/api/rpc`,
  `assets/src/lib/stream.ts` → `/ws`), so it works from any origin unchanged.
- All persistence roots derive from `Codrift.Paths.data_dir/0` /
  `config_dir/0`, both overridable via app env (the test suite already
  redirects them in `config/runtime.exs`).
- Reconnect semantics exist: per-agent output buffers, durable
  `.agent-logs` transcripts, scrollback replay via `GET /api/agent/:id/output`,
  WS heartbeats.
- `read_file` / `write_file` / `list_tree` are already contained to the
  initiative's directories with symlink-resolved checks (`Codrift.Files`).
- `Codrift.AuthToken` already provides a non-Origin bearer-token path, and
  `Codrift.Plugs.LocalGuard` is already deny-by-default on state-changing
  requests.

## What is local-bound today

| # | Assumption | Where |
|---|-----------|-------|
| 1 | Socket bound to `127.0.0.1`, port fixed at 43117 | `config/config.exs` (`bandit_opts`), `config/{dev,prod}.exs` |
| 2 | Host and Origin must be loopback; a loopback `Origin` *is* the auth | `Codrift.Plugs.LocalGuard` |
| 3 | Directories are arbitrary user-chosen host paths | `add_dir` / `list_dirs` ops in `Codrift.Core`, `Codrift.Files.subdirs/1` picker |
| 4 | Agent CLIs and their credentials live on the user's machine | `Codrift.AgentProcess` (erlexec PTY), adapters in `lib/codrift/agent/adapters/` |
| 5 | OAuth redirect URI is a registered literal `http://127.0.0.1:43117/…` — affects only the three `pkce_browser` services; the two GitHub adapters use device flow and have no redirect | `Codrift.OAuth.Config.redirect_uri/1`; provider app registrations |
| 6 | Server can open the user's browser | `open_url` op → `open_in_browser/1` in `Codrift.Core` |
| 7 | Desktop lifecycle: login-shell PATH sniffing, log redirection, port probe, heartbeat shutdown, self-update | `Codrift.start/2` (`desktop_sidecar?` branch), `Codrift.ShutdownManager`, `Codrift.Updater` |
| 8 | State lives in the user's home | `~/.codrift`, `~/.config/codrift` defaults in `Codrift.Paths` |

Everything below maps to one of these numbers.

---

## Stage A — remote single-user workspace

Target shape: a Docker image running the plain `codrift` release (the CLI
release, not `desktop` — no Burrito, no Tauri) on a VM/Fly Machine, with a
persistent volume at `/data`, behind TLS. The user opens
`https://codrift.<their-domain>` in a normal browser and gets the exact same
SPA the desktop webview shows.

### A1. Runtime configuration (blockers 1, 8)

`config/runtime.exs` gains a prod/hosted block (the test sandbox block stays):

```elixir
if config_env() == :prod do
  mode = System.get_env("CODRIFT_MODE", "local")   # "local" | "hosted"
  config :codrift, mode: String.to_existing_atom(mode)

  if mode == "hosted" do
    config :codrift,
      bandit_opts: [
        ip: {0, 0, 0, 0},
        port: String.to_integer(System.get_env("PORT", "43117"))
      ],
      public_url: System.fetch_env!("CODRIFT_PUBLIC_URL"),
      data_dir: System.get_env("CODRIFT_DATA_DIR", "/data/codrift"),
      config_dir: System.get_env("CODRIFT_CONFIG_DIR", "/data/codrift-config"),
      workspace_root: System.get_env("CODRIFT_WORKSPACE_ROOT", "/data/workspace")
  end
end
```

Notes:

- `CODRIFT_PUBLIC_URL` (e.g. `https://codrift.example.com`) is mandatory in
  hosted mode — it drives the Origin allowlist (A2) and the OAuth redirect
  base (A5). Fail loudly at boot if unset.
- Hosted mode also requires `SUPABASE_PROJECT_URL` (for the JWKS endpoint)
  and `CODRIFT_OWNER_SUB` (the Supabase user id this workspace belongs to).
  Both are read by the guard in A2; fail loudly at boot if either is unset.
  There is deliberately no `SECRET_KEY_BASE` — Codrift signs nothing, it only
  verifies Supabase's signatures.
- Binding `0.0.0.0` is safe only because the guard (A2) stops trusting
  loopback in hosted mode; land A2 in the same PR.
- A `Codrift.mode/0` helper (`Application.get_env(:codrift, :mode, :local)`)
  becomes the single switch every other change reads. Never scatter
  `System.get_env("CODRIFT_MODE")` calls.

### A2. Access guard: from LocalGuard to AccessGuard (blocker 2)

`Codrift.Plugs.LocalGuard` becomes `Codrift.Plugs.AccessGuard` with two
policies selected by `Codrift.mode/0`:

- **`:local`** — byte-for-byte today's behaviour: loopback Host, loopback
  Origin, loopback-Origin-or-token on state-changing requests. The desktop app
  must not change.
- **`:hosted`**:
  1. **Host allowlist** — request `Host` must equal the host of
     `:public_url` (the TLS proxy in front guarantees the header, this is
     defence in depth against rebinding at the proxy).
  2. **Origin allowlist** — when `Origin` is present it must equal
     `:public_url` exactly (scheme + host + port).
  3. **Auth on everything except `GET /api/health`, the static SPA assets
     and `GET /oauth/callback/*`** — not just state-changing requests. On a
     public network, `GET /api/agent/:id/output` (terminal scrollback) and
     `GET /api/diff/:id` are as sensitive as writes. Two accepted proofs:
     - a **Supabase-issued JWT** (`Authorization: Bearer`), or
     - the local bearer token (`X-Codrift-Token`), unchanged — this keeps
       `codrift mcp install`-style clients, `codrift pane` and curl working.

  Crucially, in hosted mode **a matching Origin is no longer sufficient
  auth** — it only stops CSRF. Any browser visiting the public URL sends the
  right Origin.

**Identity is Supabase Auth, not ours.** Signup, login, password reset, social
login, refresh and revocation are a solved commodity, and every hour spent on
them is an hour not spent on agents. Supabase issues the JWT; Codrift only
*verifies* it. Concretely:

- Configure the project for **asymmetric signing keys (RS256/ES256)**, not the
  HS256 default. This is not a preference. HS256 verification needs the JWT
  secret, which would have to ship inside every workspace container — so one
  compromised container could mint tokens for every user. Asymmetric keys mean
  a container holds only a public key.
- Codrift fetches and caches the JWKS from
  `https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json`, verifies
  signature, `exp` and issuer, and treats the `sub` claim as the identity.
- **Pin the owner.** A valid Supabase JWT proves the bearer is *a* Codrift
  user, not that they own *this* workspace. In hosted mode the instance reads
  `CODRIFT_OWNER_SUB` and rejects any JWT whose `sub` differs. Without this,
  every user can reach every workspace with a legitimately issued token — the
  single worst failure available in this design.
- No `SECRET_KEY_BASE`, no `POST /auth/login`, no session cookie, no rolling
  refresh, no token-paste login screen. The SPA uses `supabase-js` for the
  login screen and sends the access token it already holds.

**Why no cookie is a feature.** A first-party `SameSite=Strict` session cookie
would be withheld by the browser on exactly one request that must succeed: the
OAuth provider's cross-site top-level redirect back to
`GET /oauth/callback/:service`. Bearer JWTs have no SameSite semantics, so the
whole class of bug is gone.

**The OAuth callback must stay auth-exempt regardless.** It is the provider
redirecting the user's browser to us; it carries no `Authorization` header and
no cookie, and it never can. Its authenticity proof is the `state` parameter,
which `Codrift.OAuth.StateStore` already makes opaque, single-use,
PKCE-bound and 10-minute-expiring — which is precisely what OAuth `state` is
for. Note that the store is an in-memory `Agent`, so a machine restart drops
in-flight states; harmless (the user retries), but it is a second independent
argument against `auto_stop_machines` (see A7).

**WebSocket auth.** Browsers cannot set headers on a WS handshake, so `/ws`
accepts the JWT via the `Sec-WebSocket-Protocol` header (the one header a
browser *can* influence) or a short-lived `?access_token=` query parameter,
plus the local token header for non-browser clients. Same treatment for
`GET /mcp/sse`. The previously planned mint-a-ticket endpoint is dropped:
Supabase access tokens are already short-lived and refreshable, so minting a
second short-lived credential adds a mechanism without adding a property.

**Response codes.** Hosted mode returns 401 (not 403) for missing auth so the
SPA can distinguish "log in" from "blocked".

Tests: keep `Codrift.Web.LocalGuardTest` green untouched for `:local`; add
`AccessGuardHostedTest` covering Host/Origin spoofing, a JWT signed by the
wrong key, an expired JWT, a valid JWT whose `sub` is not the owner, WS
upgrade without a token, and the GET-requires-auth rule.

### A3. Neutralise desktop-only behaviour (blockers 6, 7)

All gated on `Codrift.mode/0 == :hosted`:

- `open_url` op: instead of `xdg-open` on the server, return
  `{:ok, %{"open" => url}}` and have the SPA call `window.open(url)`. The
  desktop keeps the server-side open (its webview can't open browsers). This
  matters because the OAuth start flow uses it.
- `Codrift.start/2`: `ensure_login_path/0`, `redirect_logs_to_file/0`,
  `warn_if_port_taken/0` and `ShutdownManager` are already gated on
  `desktop_sidecar?/0`, which is false in a container — verify with a boot
  test rather than changing code. Logs go to stdout (the platform collects
  them).
- `Codrift.Updater` / `codrift update`: return
  `{:error, "managed deployment — update the container image"}` in hosted
  mode.
- `Codrift.Files.subdirs/1` (the "add directory" autocomplete) browses the
  container FS in hosted mode. Scope it to `:workspace_root` (A4) instead of
  `~`.

### A4. Getting code into the box (blocker 3)

On a desktop, `add_dir` points at directories that already exist. In hosted
mode the code has to arrive first:

- New `clone_repo` op in `Codrift.Core`:
  `{"url", "ref?"}` → `git clone` into
  `:workspace_root/<owner>/<repo>`, then reuse the existing `add_dir` path.
  Private repos authenticate with a `GITHUB_TOKEN`-style env or, later, a
  GitHub App installation token — start with the env var, it is one user.
- `add_dir` in hosted mode validates the directory is under
  `:workspace_root` (expand + prefix check, same style as
  `Codrift.Files.read_within/2`). The per-op containment in `Files` already
  handles read/write; this closes the front door too.
- The SPA's directory picker gains a "Clone repository…" input in hosted
  mode (detected via a `get_server_info` op exposing `%{mode: "hosted"}` —
  also useful for hiding the update-check UI).
- Worktrees (`Codrift.Worktree`) work unchanged: they live next to the clone
  under the workspace root.

### A5. OAuth for integrations (blocker 5)

This is a *different* problem from A2 and Supabase does not solve it. A2 is
"prove who the user is"; this is "Codrift acting as an OAuth client against
someone else's API to read issues and projects". Supabase Auth replaces the
former and leaves the latter entirely.

The actual scope, from `Codrift.OAuth.Config`:

| Service | Flow | Redirect URI | Hosted-mode work |
|---|---|---|---|
| `github` | device_flow | none | **none** |
| `github_projects` | device_flow | none | **none** |
| `linear` | pkce_browser | yes | redirect base |
| `linear_projects` | pkce_browser | yes | redirect base |
| `gitlab` | pkce_browser | yes | redirect base |

- **GitHub needs no change at all.** Device flow has no redirect URI, so both
  GitHub adapters work in hosted mode untouched. That is two of the five.
- `Codrift.OAuth.Config.redirect_uri/1` becomes
  `"#{base_url()}/oauth/callback/#{service}"` where `base_url/0` is
  `:public_url` in hosted mode and the literal
  `http://127.0.0.1:43117` otherwise. This matters only for the three
  `pkce_browser` services.
- Those three shipped OAuth apps are registered with the loopback redirect
  only, so hosted mode needs **its own app registrations** (or, for a
  self-hoster, their own client IDs). Read
  `CODRIFT_OAUTH_<SERVICE>_CLIENT_ID` env overrides — the env-var hooks in
  `OAuth.Config` already exist for this.
- **Do not route these through Supabase social login.** Linear is not a
  Supabase provider at all, and it is two of the three remaining adapters.
  GitLab is, but using it would mean requesting integration scopes
  (`read_api read_user`) at *login* time, and `provider_token` is handed back
  at sign-in rather than being a managed, refreshing credential store — so the
  persistence and refresh code stays ours either way. Supabase would replace
  one adapter of five and make that one worse.
- Token storage is already under `data_dir` → lands on the volume. Fine for
  Stage A; revisit encryption-at-rest in Stage B.

### A6. Agents inside the container (blocker 4)

- **Image** (new top-level `Dockerfile`; the pattern in `website/Dockerfile`
  is the reference): Elixir release build stage (needs pnpm for
  `build_assets`), then a runtime stage with `git`, `bash`, `openssh-client`,
  Node.js ≥ 20, and the agent CLIs (`@anthropic-ai/claude-code`,
  `@openai/codex`, `opencode`, `@google/gemini-cli`, `@github/copilot`,
  `cursor-agent`). Ship with `claude` + shell first; add the rest as the
  image budget allows. `terminal` adapter uses `$SHELL` → set `SHELL=/bin/bash`.
- **Agent credentials**: `AgentProcess` already threads `profile_env` into
  the PTY, and agent launch profiles (`docs/agent-profiles.md`,
  `settings.json` under `data_dir`) already carry env — so
  `ANTHROPIC_API_KEY` etc. can be injected either as container secrets or
  per-profile. Document both; no code needed.
- **erlexec** compiles a port binary; confirm it builds in the image (musl vs
  glibc — prefer a Debian-slim base over Alpine to avoid the fight).
- **Resource hygiene**: agents are the workload; give the container real CPU
  and memory headroom and put the workspace + data dirs on the volume so
  clones and SQLite survive restarts.

### A7. Deployment target and lifecycle

Fly Machines first (the deploy muscle already exists in
`.github/workflows/deploy-website.yml`); anything that runs a container with
a volume works the same.

- New `fly.hosted.toml` + `deploy-hosted.yml` workflow, mirroring the website
  ones. TLS, HTTP→HTTPS and the stable hostname come from the platform;
  `CODRIFT_PUBLIC_URL` matches it.
- **Do not use `auto_stop_machines`** the way the website does: agents are
  long-lived PTYs and suspending the machine kills them silently. Start with
  `min_machines_running = 1`, exactly one machine (state is a local volume —
  never scale horizontally).
- Restart behaviour is already graceful degradation: running agents die with
  the VM, but `SessionStore` keeps session UUIDs (adapters like Claude can
  `--resume`), `.agent-logs` keep transcripts, and the SPA's health polling
  reconnects. Acceptable for Stage A; document it.
- Health check: `GET /api/health` (must stay auth-exempt).

### A8. Stage A ordering

Each step lands green (`mix check`) and never changes `:local` behaviour:

1. `Codrift.mode/0` + runtime.exs env plumbing (A1) — inert until
   `CODRIFT_MODE=hosted`.
2. AccessGuard policies + Supabase JWT verification + owner pinning (A2). The
   security core; biggest test surface.
3. Desktop-behaviour gating + `get_server_info` (A3).
4. `clone_repo` + workspace-root scoping (A4).
5. OAuth base-URL indirection (A5).
6. Dockerfile + boot smoke test (A6).
7. Fly config + deploy workflow + docs (A7).

Steps 3–6 are independent of each other once 1–2 are in.

## Stage B — multi-tenant service

Only sketched here; specify properly once Stage A runs in anger.

**Architecture:** a thin control plane (accounts, billing, workspace
lifecycle) plus a fleet of Stage-A instances, one per user, each in its own
micro-VM (Fly Machines per-app, or Firecracker/gVisor elsewhere) with its own
volume. The Codrift image is unchanged from Stage A.

**Supabase is the control plane's spine.** Accounts, sessions, social login
and the workspace table (Postgres + RLS) are exactly the commodity half of
this, and Stage A already verifies Supabase JWTs (A2) — so Stage B inherits
its auth rather than inventing it. What is left to build is the part nobody
sells: workspace provisioning and the proxy.

Because every workspace already verifies the same JWKS, the proxy **forwards
the user's own JWT** rather than injecting a per-instance bearer token. That
removes per-instance secret management entirely, at the cost of one rule that
must not be got wrong: each instance pins `CODRIFT_OWNER_SUB` and rejects any
`sub` that is not its owner (A2). The instance, not the proxy, is the
authority on who owns it — a proxy bug then leaks nothing.

**Supabase is not the compute substrate.** It does not run long-lived PTYs, a
persistent local disk, or kernel-isolated per-user VMs — requirements 1–5
below. It replaces the control plane's auth and database; the provider
question is untouched by choosing it.

**Per-instance lifecycle:** create (provision app + volume + secrets), wake
on request, idle-stop only when `list_agents` reports nothing running, destroy
with volume snapshot export.

**The honest cost centre — arbitrary code execution as a service:**

- Kernel-level isolation per user (micro-VMs, not shared-kernel containers).
- Egress policy per instance: default-allow is untenable — an agent that
  reads a malicious issue body can be prompt-injected into exfiltrating the
  instance's tokens. Start with an allowlist proxy (VCS hosts, package
  registries, model APIs) and make it configurable.
- Quotas: CPU, memory, disk, process count (`erlexec` makes runaway PTYs
  killable), and spend caps on model APIs if keys are platform-provided.
- Secrets: per-instance OAuth tokens and agent keys scoped so one instance's
  compromise exposes only that user.

**Stage A decisions that keep B cheap:** single instance = single tenant (no
shared state to untangle); `CODRIFT_PUBLIC_URL`-driven guard works unchanged
behind a proxied subdomain-per-user; Supabase JWT verification means the proxy
forwards a credential it never has to mint; all state under two env-pointed
roots makes volumes and snapshots trivial.

## Website (codrift.app)

The site today is a stateless single-page Francis app (`website/`) on Fly:
one EEx template, Tailwind, `install.sh`, and a version chip cached from the
GitHub releases API. Two constraints drive everything below:

- **It suspends.** `min_machines_running = 0` + `auto_stop_machines =
  "suspend"` means no background jobs and no local persistence — the
  `Website.Version` moduledoc exists because of exactly this. Any feature
  needing durable state must keep its state elsewhere.
- **It is the trust anchor.** `install.sh` is piped to `sh` from this domain
  and the OAuth success pages point users back at it. It should stay small,
  boring and hard to break; the hosted product must not turn it into an app.

Decision: the website stays a stateless marketing/docs surface in both
stages. The hosted product gets its own origin (`app.codrift.app`) in
Stage B, and the website only ever links to it. Growing `website/` into the
control plane (DB, auth, billing in the same app that serves `install.sh`)
is rejected for the same reason in-process multi-tenancy was: it couples the
highest-trust artifact to the highest-churn code.

### W1 — ship with Stage A (content only, no new state)

Stage A users self-host, so the website's job is to explain and sell that:

1. **A "Hosted" section on the landing page** — new `<section id="hosted">`
   in `index.html.eex` between install and the footer, in the existing
   channel-numbered style. Message: same binary, `CODRIFT_MODE=hosted`, your
   own server, browser instead of webview. One screenshot of the SPA in a
   normal browser tab (the same shot pipeline as the existing `.webp`s), the
   `docker run` one-liner with the required envs, and a link to the guide.
   Nav gains a "Hosted" anchor next to "The floor / Conductor / Keys".
2. **Self-host guide at `/hosted`** — a real page, not just the repo doc:
   prerequisites, the env table (`CODRIFT_MODE`, `CODRIFT_PUBLIC_URL`,
   `SUPABASE_PROJECT_URL`, `CODRIFT_OWNER_SUB`, `PORT`, data/workspace
   dirs), volume layout, first login, agent credential injection via
   profiles, the
   OAuth client-ID caveat from A5, and a copy-paste `fly.toml`. Implemented
   as a second EEx template + route in `website.ex` (the app already renders
   EEx per-request; a second template costs nothing). Content is authored as
   the canonical `docs/hosting-guide.md` in the repo and converted at build
   time — one source, rendered both on GitHub and on the site.
3. **Container image distribution** — the guide needs an image to point at.
   Publish `ghcr.io/filipecabaco/codrift` from `release.yml` on the same
   tags that build the desktop bundles (the Dockerfile from A6). The
   website's version chip already tracks releases, so the guide can render
   the current image tag with the existing `Website.Version` — no new
   plumbing.
4. **Interest capture, statelessly** — a "want this managed for you?" card
   in the hosted section. No form: a `mailto:` + a link to a pinned GitHub
   Discussion. Zero state, real signal, and it sizes demand for Stage B
   before any control-plane code exists. A form-with-database is Stage B
   work; do not build a waitlist backend into the suspending site.

Ordering: W1.3 (image publishing) rides the Stage A6/A7 PR; W1.1/W1.2 land
together once a hosted instance actually runs (screenshots need it); W1.4 is
a one-line addition to W1.1.

### W2 — ship with Stage B (the product gets its own origin)

- **`app.codrift.app`** — the control plane from Stage B: signup (Supabase
  Auth), workspace provisioning, billing, and the proxy into per-user
  instances (each reachable as `<user>.app.codrift.app` or a path prefix —
  decide when building the proxy; subdomains keep the AccessGuard's
  origin-allowlist model unchanged, so prefer them). This is a **new app**
  (`cloud/` or its own repo), with a database, on always-on machines —
  everything the website deliberately isn't.
- **Website changes stay cosmetic**: the hosted section's CTA flips from
  "read the guide" to "Sign in / Start a workspace →" pointing at
  `app.codrift.app`; pricing section (static content — prices change by
  deploy, which is fine at this scale); the self-host guide remains, clearly
  marked as the free path.
- **Shared look, not shared code**: extract the Tailwind theme
  (`assets/css/app.css` tokens, Archivo/JetBrains Mono, the channel-number
  idiom) into a copied preset for the control plane's UI so the two origins
  read as one product. Don't create a shared package for two consumers.
- **Legal pages** — ToS and privacy policy become mandatory the moment
  signups exist. Static EEx pages on the website (`/terms`, `/privacy`),
  linked from both origins' footers.
- **Status visibility** — a `/status` link in the footer pointing at a
  hosted status page (external service; the website must not monitor the
  fleet — it suspends). Instance health belongs to the control plane.

### What deliberately does not change

- `install.sh`, the release download links and the desktop story stay
  front-and-centre — hosted is an addition, not a pivot, and the landing
  page's primary CTA remains the install command.
- The website keeps `min_machines_running = 0`. Nothing in W1 or W2 gives it
  state or background work; if a feature seems to need either, it belongs in
  the control plane.

## Compute providers (the Stage B substrate)

### What Codrift actually needs

The requirements come from the code, and they rule out most of the market
before pricing is even discussed:

1. **A stateful server per user, not a function.** `Codrift.start/2`
   supervises registries, stores and dynamic supervisors that must stay alive
   for the whole session.
2. **Long-lived PTY children.** `AgentProcess` runs `:exec.run(cmd, [:pty…])`;
   agents live for hours, and `:exec.winsz/3` needs a real terminal.
3. **Inbound long-lived connections.** `/ws` (30 s heartbeat, 90 s timeout)
   and `/mcp/sse` must be reachable *into* the VM. Request/response-only
   platforms are out.
4. **A real local disk.** Git clones, worktrees, `.agent-logs`, and SQLite —
   `SessionStore` plus per-initiative FTS5 memory DBs. Network filesystems
   are a bad host for SQLite and for git object churn.
5. **Kernel-level isolation.** Agents execute arbitrary shell commands.
   Shared-kernel containers are not a tenant boundary.
6. **Scale-to-zero with state.** A workspace is active a few hours a day and
   idle the rest. Paying 24/7 per user destroys the unit economics.
7. **Fast wake.** Open laptop, workspace is there.
8. **Egress control.** Prompt-injection exfiltration is the threat model.

### The fork that decides the shortlist

- **Option 1 — ship the whole Codrift image into the tenant VM.** The Stage A
  container *is* the workspace. Needs a provider that runs your OCI image
  with your server listening on a port, addressable from outside.
- **Option 2 — central Codrift server driving remote sandboxes.** Requires
  replacing `AgentProcess`'s erlexec PTY with a remote-exec API and
  `Files`/`Diff`/`Worktree`'s local FS calls with remote ones — i.e. gutting
  the layer the whole app is built on.

**Take Option 1.** It reuses Stage A verbatim and keeps the "single instance =
single tenant" property that makes Stage B cheap. This is the decisive filter:
it demotes the exec-SDK sandbox platforms (E2B, Modal, Daytona), whose
programming model is "call an API to run code in a box", not "host my
long-running server".

### Shortlist

| Provider | Isolation | Fit | Watch out for |
|---|---|---|---|
| **Fly Machines** | Firecracker | Runs any OCI image; REST API to create/start/stop/suspend/destroy; volumes; wake-on-request via the proxy; WS/SSE fine. We already deploy here. | Volumes are host-pinned (no live migration) and bill whether the machine runs or not ($0.15/GB/mo); snapshots billable since Jan 2026 ($0.08/GB/mo). Never scale a workspace horizontally. |
| **Fly Sprites** | Firecracker | Purpose-built for this shape: persistent microVM, ~100 GB object-storage-backed filesystem that survives indefinitely, auto-sleep when idle, wake on request to its URL, billed only while awake and by bytes actually written. Reported ~$0.46 for a 4-hour coding session. | New (launched Jan 2026) — maturity unproven. **Blocking question below.** |
| **Northflank (BYOC)** | Kata / Cloud Hypervisor / Firecracker / gVisor, per workload | Any OCI image, sessions with no platform-imposed time limit, self-serve BYOC into AWS/GCP/Azure/bare metal. The answer if a customer demands "run inside our VPC". | More platform surface to learn; BYOC means you operate the cloud account. |
| **K8s + Kata/gVisor** (incl. the Kubernetes SIG *Agent Sandbox* project — declarative stateful sandbox pods, gVisor default, Kata opt-in) | Kata (VM) or gVisor | Maximum control; the right shape at real scale. | Real ops burden. Wrong first move for a small team. |
| **Own Firecracker fleet on bare metal** (Hetzner/OVH) | Firecracker | Cheapest per core by a wide margin. | You are now an infrastructure company. A later cost optimisation, not a starting point. |

**Not a fit, and why:**

- **Shared-kernel PaaS** (Railway, Render, Heroku-likes) — wrong isolation for
  arbitrary code execution, regardless of how pleasant the DX is.
- **AWS Fargate + EFS** — Firecracker under the hood, but slow starts, no
  scale-to-zero-with-state, and EFS latency is poor for git and SQLite.
- **Cloudflare Containers/Sandboxes** — GA April 2026 with generous limits,
  but the model is Durable-Object-driven and exec-oriented; a persistent BEAM
  workspace with a durable 100 GB disk isn't its sweet spot.
- **E2B / Modal / Daytona** — good products for Option 2, not Option 1. Worth
  knowing as pricing anchors (E2B and Daytona both list ~$0.0504/vCPU-hr +
  ~$0.0162/GiB-hr). E2B caps sessions at 1 h (Hobby) / 24 h (Pro), which is
  disqualifying for a persistent workspace; Modal uses gVisor, a thinner
  boundary than a microVM.
- **Coder / Codespaces** — solve workspace lifecycle, but they are the
  competing product's shape; embedding one means adopting its workspace model
  instead of Codrift's initiatives.

### Recommendation

**Fly, in two steps.** Build Stage B on the **Machines API** — proven, we
already operate there, and it gives full explicit control of the workspace
lifecycle (create app + volume + secrets, start, stop, destroy, snapshot).
Then **evaluate Sprites** as the target substrate, because its product shape
is almost exactly Codrift's workspace: persistent filesystem, sleeps when
nobody is looking, wakes on a request, bills only for awake time.

Keep the provider behind a `Codrift.Cloud.Backend` behaviour in the control
plane (`provision/1`, `wake/1`, `sleep/1`, `destroy/1`, `snapshot/1`) with a
Machines implementation first. Two implementations of a five-callback
behaviour is a cheap hedge; a rewrite is not. **Northflank BYOC** is the
designated fallback and the enterprise/VPC answer.

### The blocking question for Sprites

> This is also the largest brand risk in `go-to-market.md`: the hosted claim is
> that work continues while nobody is watching. A workspace that suspends
> mid-task does not merely cost a support ticket, it inverts the proposition
> into "it quietly stopped". Resolve it before the claim is made publicly.


Sprites sleep after ~30 s of *inactivity*. **Does CPU activity inside the VM
count as activity, or only inbound requests?** Codrift's normal state is an
agent working for ten minutes while the user watches another pane — if only
inbound traffic counts, the workspace suspends mid-task. A suspend is a memory
snapshot, so the agent would resume rather than die, but a silently stalled
agent is a broken product.

Answer this before committing. Adjacent must-verifies: can a Sprite hold an
inbound WebSocket open for hours, and does wake-on-request fire for a WS
upgrade (not just plain HTTP)? Fly's docs were unreachable from the
environment this plan was written in, so every Sprites figure above is from
secondary sources and needs confirming against fly.io directly.

### Cost model (sets the price floor)

One workspace at 2 vCPU / 4 GB, active 4 h/day × 20 days = 80 h/month, at the
~$0.0504/vCPU-hr + ~$0.0162/GiB-hr rates the market currently converges on:

- Compute: `(2 × 0.0504) + (4 × 0.0162)` = **$0.166/hr** → ~**$13/mo**
- Storage: 30 GB at $0.15/GB/mo → **$4.50/mo** (Fly volumes bill even when
  stopped; Sprites' write-based billing should undercut this)
- **≈ $18/user/month** before egress, control-plane and support.

So a $29/mo tier has thin margin once support and heavy users are priced in;
$49 is the realistic entry point, and idle-suspend behaviour is the single
biggest lever on that number. Model API keys should be BYO at launch —
absorbing agent inference cost changes the business, not just the margin.

## Out of scope

- Collaborative/multi-user access to one workspace (the model is one
  supervisor per workspace).
- Replacing the desktop app — local stays the primary product; hosted is the
  same binary in a different mode.
- Horizontal scaling of a single instance (state is local SQLite + files by
  design).

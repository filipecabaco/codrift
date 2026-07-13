# Integration Setup

How to make Codrift's external integrations (GitHub, Linear, GitLab) work
**out of the box** in a released binary — so users can authorize in-app without
setting any environment variables.

The integrations are already built to require **no client secrets**. All three
services use secret-less OAuth flows:

- **GitHub** — Device Flow (RFC 8628): user enters a short code at
  `github.com/login/device`. No redirect URI, no secret.
- **Linear / GitLab** — PKCE (RFC 7636): browser redirect to
  `localhost:7437`. No secret.

The only setup needed is to register a developer OAuth app per service, copy its
**public** client ID, and paste it into `lib/codrift/oauth/config.ex`. Client IDs
are public identifiers, safe to commit and ship in the binary — they are not
secrets.

> **Who does this:** you (the maintainer) register three OAuth apps under your
> own GitHub/Linear/GitLab accounts. End users then authorize against them —
> there is no per-user registration.

---

## 1. GitHub — covers `github` and `github_projects`

1. Go to **github.com → Settings → Developer settings → OAuth Apps →
   [New OAuth App](https://github.com/settings/applications/new)**.
2. Fill in:
   - **Application name:** `Codrift`
   - **Homepage URL:** any URL (e.g. `https://github.com/filipecabaco/codrift`)
   - **Authorization callback URL:** **leave blank** (Device Flow has no callback)
3. Click **Register application**.
4. Copy the **Client ID**. Do **not** generate a client secret.

Scopes requested at auth time: `repo read:org project`.

---

## 2. Linear — covers `linear` and `linear_projects`

1. Go to **linear.app → Settings → API → OAuth applications →
   [Create application](https://linear.app/settings/api/applications/new)**.
2. Fill in:
   - **Application name:** `Codrift`
   - **Redirect URI:** `http://localhost:7437/oauth/callback/linear`
3. Click **Create**.
4. Copy the **Client ID**. Ignore the client secret field — PKCE does not use it.

`linear` and `linear_projects` share the same client ID and token.

---

## 3. GitLab (gitlab.com)

1. Go to **gitlab.com → Preferences → Applications →
   [Add new application](https://gitlab.com/-/profile/applications)**.
2. Fill in:
   - **Name:** `Codrift`
   - **Redirect URI:** `http://localhost:7437/oauth/callback/gitlab`
   - **Confidential:** **unchecked** — this marks it as a public client, enabling
     PKCE without a secret.
   - **Scopes:** `read_api`, `read_user`
3. Click **Save application**.
4. Copy the **Application ID** (= client ID). Public apps have no secret.

> **Self-hosted GitLab** is not covered by the bundled ID. Those users must
> register their own app on their instance and set `GITLAB_CLIENT_ID` +
> `GITLAB_HOST` themselves.

---

## 4. Paste the client IDs into config

In `lib/codrift/oauth/config.ex`, replace each `client_id: nil` with the
registered ID. Two pairs share an ID, so this is three distinct values across
five fields:

```elixir
"github" =>          %{ ... client_id: "Ov23li...",      ... },
"github_projects" => %{ ... client_id: "Ov23li...",      ... },  # same GitHub ID
"linear" =>          %{ ... client_id: "<linear-id>",    ... },
"linear_projects" => %{ ... client_id: "<linear-id>",    ... },  # same Linear ID
"gitlab" =>          %{ ... client_id: "<gitlab-app-id>", ... },
```

`resolve_client_id/2` reads the `{SERVICE}_CLIENT_ID` env var first and falls
back to this field, so once these ship, released binaries authorize with **zero
env vars**.

---

## Redirect URIs (must match exactly)

The callback port `7437` is hardcoded. The registered redirect URI must match
character-for-character or Linear/GitLab will reject the flow:

| Service | Redirect URI |
|---|---|
| GitHub | *(none — Device Flow)* |
| Linear | `http://localhost:7437/oauth/callback/linear` |
| GitLab | `http://localhost:7437/oauth/callback/gitlab` |

---

## Env var fallback (works today, no registration)

Integrations already work for anyone who supplies their own credentials — the
registration above only makes them work *out of the box*. Users can instead set:

| Service | Client env var | Personal-token fallback |
|---|---|---|
| GitHub Issues / Projects | `GITHUB_CLIENT_ID` | `GITHUB_TOKEN` (+ `GITHUB_REPO`) |
| Linear Issues / Projects | `LINEAR_CLIENT_ID` | `LINEAR_API_KEY` |
| GitLab Issues | `GITLAB_CLIENT_ID` | `GITLAB_TOKEN` (+ `GITLAB_PROJECT`, `GITLAB_HOST`) |

---

## Verifying

After setting the IDs and running the app:

```sh
codrift integration services        # lists supported services
codrift integration auth github     # runs the Device Flow / PKCE browser flow
codrift integration tokens          # shows currently connected services
codrift integration import github 42  # seed an initiative from an issue
```

Tokens are stored at `~/.codrift/oauth_tokens.json` (mode 0600). No secret is
stored in or shipped with the binary.

See [integrations.md](integrations.md) for the full per-service reference and
revocation steps.

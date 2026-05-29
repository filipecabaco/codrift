# Integration Setup

Codrift can pull context from GitHub, Linear, GitLab, Jira, and Notion. Each
service has two auth paths:

- **OAuth (recommended)** — handled entirely inside the TUI. Codrift stores the
  token in `~/.codrift/oauth_tokens.json` (mode 0600). No secret is ever stored
  or shipped in the binary.
- **Env var fallback** — for CI, headless environments, or personal tokens. Set
  the variables listed under each service and Codrift will use them automatically.

---

## Quick start

1. Register a developer app for the services you want (instructions below).
2. Set the `*_CLIENT_ID` env var for each service.
3. Open the TUI (`codrift tui`), press `Ctrl+P` → **Integrations** to connect.
4. Press `n` → pick a service from the source picker to import an issue as an
   initiative.

---

## GitHub — Issues and Projects

**Auth flow:** Device Flow (RFC 8628). No redirect URI. No client secret.

### Register an OAuth App

1. Go to **github.com → Settings → Developer settings → OAuth Apps**
   → [New OAuth App](https://github.com/settings/applications/new)
2. Fill in:
   - **Application name:** `Codrift`
   - **Homepage URL:** any URL (e.g. `https://github.com/your-org/codrift`)
   - **Authorization callback URL:** leave blank (Device Flow has no callback)
3. Click **Register application**.
4. Copy the **Client ID** shown on the app page. Do **not** generate a client secret.

**GitHub docs:**
- [Creating an OAuth App](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app)
- [Device authorization grant](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow)

### Configure

```sh
export GITHUB_CLIENT_ID="your-github-client-id"
```

Or hardcode it in `lib/codrift/oauth/config.ex` under the `"github"` key for
distribution.

### Env var fallback (no OAuth app)

```sh
export GITHUB_TOKEN="ghp_..."   # PAT with repo + project scopes
export GITHUB_REPO="owner/repo" # default repo for issue lookups
```

Generate a PAT at [github.com/settings/tokens](https://github.com/settings/tokens).
Required scopes: `repo`, `read:org`, `project` (for Projects v2).

---

## Linear — Issues and Projects

**Auth flow:** PKCE (RFC 7636). Redirect to `localhost:7437`. No client secret.

### Register an OAuth Application

1. Go to **linear.app → Settings → API → OAuth applications**
   → [Create application](https://linear.app/settings/api/applications/new)
2. Fill in:
   - **Application name:** `Codrift`
   - **Redirect URI:** `http://localhost:7437/oauth/callback/linear`
3. Click **Create**.
4. Copy the **Client ID**. Ignore the client secret field — PKCE does not need it.

**Linear docs:**
- [OAuth 2.0 authentication](https://developers.linear.app/docs/oauth/authentication)
- [Creating an OAuth application](https://developers.linear.app/docs/oauth/authentication#create-an-oauth-application)

### Configure

```sh
export LINEAR_CLIENT_ID="your-linear-client-id"
```

`linear` and `linear_projects` share the same client ID and token.

### Env var fallback

```sh
export LINEAR_API_KEY="lin_api_..."
```

Generate a personal API key at
[linear.app/settings/api](https://linear.app/settings/api).

---

## GitLab — Issues

**Auth flow:** PKCE (RFC 7636). Redirect to `localhost:7437`. Registered as a
**public** application (no secret).

### Register an Application

1. Go to **gitlab.com → Preferences → Applications**
   → [Add new application](https://gitlab.com/-/profile/applications)
2. Fill in:
   - **Name:** `Codrift`
   - **Redirect URI:** `http://localhost:7437/oauth/callback/gitlab`
   - **Confidential:** **unchecked** (this marks it as a public client enabling PKCE without a secret)
   - **Scopes:** `read_api`, `read_user`
3. Click **Save application**.
4. Copy the **Application ID** (= client ID). There is no secret for public apps.

For **self-hosted GitLab**, use your instance's admin panel instead and also set
`GITLAB_HOST` (see env vars below).

**GitLab docs:**
- [Configure GitLab as an OAuth 2.0 authentication identity provider](https://docs.gitlab.com/ee/integration/oauth_provider.html)
- [OAuth 2.0 with PKCE](https://docs.gitlab.com/ee/api/oauth2.html#authorization-code-with-proof-key-for-code-exchange-pkce)

### Configure

```sh
export GITLAB_CLIENT_ID="your-gitlab-application-id"
```

### Env var fallback

```sh
export GITLAB_TOKEN="glpat-..."     # personal access token
export GITLAB_PROJECT="group/repo"  # project path (URL-encoded internally)
export GITLAB_HOST="gitlab.mycompany.com"  # only for self-hosted; defaults to gitlab.com
```

Generate a personal access token at
[gitlab.com/-/user_settings/personal_access_tokens](https://gitlab.com/-/user_settings/personal_access_tokens)
with `read_api` scope.

---

## Jira — Cloud Issues

**Auth flow:** PKCE (RFC 7636). Redirect to `localhost:7437`. After the token
exchange, Codrift automatically fetches your Atlassian **cloud ID** and site URL
from the accessible-resources API and stores them alongside the token. No manual
configuration of `JIRA_HOST` is needed when using OAuth.

### Register an OAuth 2.0 Integration

1. Go to **developer.atlassian.com → My Apps**
   → [Create](https://developer.atlassian.com/console/myapps/create)
   → **OAuth 2.0 integration**
2. Fill in:
   - **App name:** `Codrift`
3. Under **Authorization**:
   - Click **Add** next to **OAuth 2.0 (3LO)**
   - Set **Callback URL:** `http://localhost:7437/oauth/callback/jira`
4. Under **Permissions**:
   - Add **Jira API** → `read:jira-work`, `read:jira-user`
   - Also add **User identity API** → `read:account` (required for user lookups)
5. Under **Distribution** → set **Sharing** to **Sharing** so other users can
   authorize. Leave it as **Restricted** if this is only for your own account.
6. Under **Settings** → copy the **Client ID**. Do **not** copy the secret —
   PKCE does not use it.

> **Note:** Atlassian requires `offline_access` scope for refresh tokens. This
> is already included in Codrift's scope list. Atlassian may prompt you to
> consent to offline access during the first authorization.

**Atlassian docs:**
- [OAuth 2.0 apps (3LO)](https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/)
- [Accessible resources](https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/#3--get-the-cloudid-for-your-site)

### Configure

```sh
export JIRA_CLIENT_ID="your-atlassian-client-id"
```

### Env var fallback

```sh
export JIRA_HOST="mycompany.atlassian.net"
export JIRA_EMAIL="you@mycompany.com"
export JIRA_TOKEN="..."   # API token, not your password
```

Generate an API token at
[id.atlassian.com/manage-profile/security/api-tokens](https://id.atlassian.com/manage-profile/security/api-tokens).

---

## Notion — Pages and Databases

**Auth flow:** Guided token. No OAuth app registration required. Notion issues a
permanent integration token through their web UI.

### Create an Internal Integration

1. Go to [notion.so/profile/integrations](https://www.notion.so/profile/integrations)
   → **New integration**
2. Fill in:
   - **Name:** `Codrift`
   - **Associated workspace:** select your workspace
   - **Type:** **Internal** (not public)
3. Under **Capabilities**: ensure **Read content** is checked.
4. Copy the **Internal Integration Secret** (starts with `secret_` or `ntn_`).

**Share databases with your integration:**
For each Notion database you want Codrift to access, open the database in Notion
→ `...` menu → **Connections** → find your integration and click **Confirm**.

**Notion docs:**
- [Create an integration](https://developers.notion.com/docs/create-a-notion-integration)
- [Authorizing integrations](https://developers.notion.com/docs/authorization)

### Configure

In the TUI: `Ctrl+P` → **Integrations** → select **Notion** → Enter → follow
the prompts to paste your token. No env var needed for interactive use.

### Env var fallback

```sh
export NOTION_API_KEY="secret_..."
export NOTION_DATABASE_ID="32-char-database-id"   # default database for list_items
```

---

## Summary table

| Service | Flow | Env var: client | Env var: fallback token |
|---|---|---|---|
| GitHub Issues | Device Flow | `GITHUB_CLIENT_ID` | `GITHUB_TOKEN` |
| GitHub Projects v2 | Device Flow | `GITHUB_CLIENT_ID` | `GITHUB_TOKEN` |
| Linear Issues | PKCE | `LINEAR_CLIENT_ID` | `LINEAR_API_KEY` |
| Linear Projects | PKCE | `LINEAR_CLIENT_ID` | `LINEAR_API_KEY` |
| GitLab Issues | PKCE | `GITLAB_CLIENT_ID` | `GITLAB_TOKEN` |
| Jira Cloud | PKCE + cloudId | `JIRA_CLIENT_ID` | `JIRA_HOST` + `JIRA_EMAIL` + `JIRA_TOKEN` |
| Notion | Guided token | — | `NOTION_API_KEY` |

---

## Distributing Codrift with client IDs pre-configured

Client IDs are safe to commit — they are public identifiers, not secrets. Once
you have registered apps for each service, set the `client_id` field directly in
`lib/codrift/oauth/config.ex`:

```elixir
"github" => %{
  flow: :device_flow,
  ...
  client_id: "Ov23li...",   # your registered GitHub OAuth App client ID
  ...
}
```

Users who run the released binary will then be able to authorize without setting
any env vars.

---

## Revoking access

From the TUI: `Ctrl+P` → **Integrations** → navigate to the service → press `r`.

From the CLI:
```sh
codrift integration revoke github
codrift integration tokens   # list currently connected services
```

Tokens are stored in `~/.codrift/oauth_tokens.json`. You can also delete the
file directly to revoke all services at once.

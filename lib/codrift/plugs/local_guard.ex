defmodule Codrift.Plugs.LocalGuard do
  @moduledoc """
  Guards the local HTTP surface of the loopback server.

  The socket is bound to loopback, but loopback alone stops neither a
  malicious web page the user visits (cross-origin `fetch` / DNS rebinding)
  nor other local processes from scripting requests at
  `http://localhost:<port>/…` — and those routes can write files and spawn
  agents (`POST /api/rpc`, `POST /mcp`, `ws /ws/agent/:id`).

  Three checks close that gap:

    1. **Host allowlist** — the request's `Host` must be a loopback name.
       A DNS-rebinding page reaches the socket but carries its own hostname in
       `Host` (e.g. `attacker.com`), so it is rejected.

    2. **Origin allowlist** — when an `Origin` header is present it must be
       loopback. Browsers attach `Origin` to cross-site `fetch`/XHR and
       WebSocket handshakes, so a page on `https://evil.example` is rejected.

    3. **Auth on state-changing requests** — `POST`/`PUT`/`PATCH`/`DELETE`
       and WebSocket upgrades must prove where they come from: either a
       loopback `Origin` (browsers always attach `Origin` to those requests
       and pages cannot forge it — this is the app's own webview) or the
       local token from `~/.codrift/auth-token` (see `Codrift.AuthToken`)
       sent as `X-Codrift-Token` or `Authorization: Bearer …`. This is
       deny-by-default: a state-changing request with neither is rejected,
       so a missing header can never downgrade the guard.

  Reads (`GET` without upgrade, e.g. the OAuth provider's top-level redirect
  to `/oauth/callback/*` and the SSE streams) pass on checks 1–2 alone:
  browsers cannot read cross-origin responses without CORS headers, which
  this server never sends.

  Runs before every route (declared as a `plug` ahead of the route macros).
  Disabled via `config :codrift, :http_guard_enabled, false` — the test suite
  turns it off so unit tests can use Plug.Test's default host, and exercises
  the guard explicitly in `Codrift.Web.LocalGuardTest`.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if enabled?() do
      guard(conn)
    else
      conn
    end
  end

  defp guard(conn) do
    cond do
      not loopback_host?(conn.host) ->
        forbid(conn, "non-local Host header")

      cross_origin?(conn) ->
        forbid(conn, "cross-origin request")

      state_changing?(conn) and not authorized?(conn) ->
        forbid(conn, "missing auth: send a loopback Origin or the ~/.codrift/auth-token token")

      true ->
        conn
    end
  end

  defp state_changing?(conn) do
    conn.method in ~w(POST PUT PATCH DELETE) or websocket_upgrade?(conn)
  end

  defp websocket_upgrade?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  # A present Origin is already known to be loopback here (cross_origin?/1
  # rejected everything else), which identifies the app's own webview:
  # browsers always attach Origin to POSTs and WS handshakes and pages cannot
  # forge it. Everything else must present the local token.
  defp authorized?(conn) do
    get_req_header(conn, "origin") != [] or valid_token?(conn)
  end

  defp valid_token?(conn) do
    case provided_token(conn) do
      nil -> false
      token -> Plug.Crypto.secure_compare(token, Codrift.AuthToken.fetch())
    end
  end

  defp provided_token(conn) do
    case get_req_header(conn, "x-codrift-token") do
      [token | _] ->
        token

      [] ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token | _] -> token
          _ -> nil
        end
    end
  end

  # True when an Origin header is present and its host is not loopback. A missing
  # Origin is not cross-origin (non-browser client / top-level navigation).
  defp cross_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] -> false
      [origin | _] -> not loopback_origin?(origin)
    end
  end

  defp loopback_origin?(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) -> loopback_host?(host)
      _ -> false
    end
  end

  # Loopback hostnames per RFC 6761: `localhost` and any `*.localhost` always
  # resolve to loopback (this also covers Tauri's `tauri.localhost` origin), plus
  # the literal loopback IPs.
  defp loopback_host?(host) when is_binary(host) do
    host = String.downcase(host)

    host == "localhost" or String.ends_with?(host, ".localhost") or
      host == "::1" or host == "0:0:0:0:0:0:0:1" or String.starts_with?(host, "127.")
  end

  defp loopback_host?(_), do: false

  defp forbid(conn, reason) do
    conn
    |> send_resp(403, "forbidden: #{reason}")
    |> halt()
  end

  defp enabled?, do: Application.get_env(:codrift, :http_guard_enabled, true)
end

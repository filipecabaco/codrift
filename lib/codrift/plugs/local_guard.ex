defmodule Codrift.Plugs.LocalGuard do
  @moduledoc """
  Guards the local HTTP surface against browser-borne attacks on the loopback
  server.

  Codrift's routes are unauthenticated by design (it's a single-user desktop
  sidecar), and the socket is bound to loopback. But loopback alone does not
  stop a malicious web page the user visits from scripting requests at
  `http://localhost:<port>/…` — via a plain cross-origin `fetch` or a
  DNS-rebinding attack — and those routes can write files and spawn agents
  (`POST /api/rpc`, `POST /mcp`, `ws /ws/agent/:id`).

  Two checks close that gap:

    1. **Host allowlist** — the request's `Host` must be a loopback name.
       A DNS-rebinding page reaches the socket but carries its own hostname in
       `Host` (e.g. `attacker.com`), so it is rejected.

    2. **Origin allowlist** — when an `Origin` header is present it must also be
       loopback. Browsers attach `Origin` to cross-site `fetch`/XHR and WebSocket
       handshakes, so a page on `https://evil.example` is rejected. A *missing*
       `Origin` is allowed: that covers non-browser clients (the MCP client,
       curl) and top-level browser navigations (the OAuth provider redirect to
       `/oauth/callback/*`), none of which are cross-origin script requests.

  Runs before every route (declared as a `plug` ahead of the route macros).
  Disabled via `config :codrift, :http_guard_enabled, false` — the test suite
  turns it off so unit tests can use Plug.Test's default host, and exercises the
  guard explicitly in `Codrift.Web.LocalGuardTest`.
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

      true ->
        conn
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

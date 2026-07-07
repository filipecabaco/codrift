import Config

# Tauri desktop shell (ex_tauri). The webview points at the Francis server, which
# listens on 7437 in every env (see dev.exs / prod.exs bandit_opts).
config :ex_tauri,
  app_name: "Codrift",
  host: "localhost",
  port: 7437,
  version: "2.5.1",
  # Launch windowed as a roomy "operating system for agents": the Rust setup
  # hook (src-tauri/src/lib.rs) resizes to 80% of the primary monitor and
  # centers. These width/height are only the pre-resize fallback if that hook
  # can't read the monitor. Kept in sync with src-tauri/tauri.conf.json so
  # re-running `mix ex_tauri.install` regenerates the same window (ex_tauri
  # reads these keys, see helpers.ex).
  fullscreen: false,
  width: 1440,
  height: 900

# Serve priv/static app-relative (via :code.priv_dir) so it resolves inside a
# release too — the default "priv/static" is cwd-relative and 404s in releases
# (e.g. the ex_tauri desktop build).
config :francis, static: [from: {:codrift, "priv/static"}, at: "/"]

# Bind the HTTP server to the loopback interface only. Codrift is a local
# desktop sidecar and its routes (POST /api/rpc → Core.write_file/start_agent,
# the OAuth callback) are unauthenticated, so the socket must never be reachable
# from the LAN. Config deep-merges this with each env's `port` in *.exs.
config :codrift, bandit_opts: [ip: {127, 0, 0, 1}]

import_config "#{config_env()}.exs"

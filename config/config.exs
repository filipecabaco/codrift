import Config

# Tauri desktop shell (ex_tauri). The webview points at the Francis server, which
# listens on 7437 in every env (see dev.exs / prod.exs bandit_opts).
config :ex_tauri,
  app_name: "Codrift",
  host: "localhost",
  port: 7437,
  version: "2.5.1"

# Serve priv/static app-relative (via :code.priv_dir) so it resolves inside a
# release too — the default "priv/static" is cwd-relative and 404s in releases
# (e.g. the ex_tauri desktop build).
config :francis, static: [from: {:codrift, "priv/static"}, at: "/"]

import_config "#{config_env()}.exs"

import Config

config :francis, dev: false

# The ex_tauri desktop release runs in prod; serve on the same port the webview
# targets.
config :codrift, bandit_opts: [port: 7437]

config :codrift, Codrift.Scheduler,
  jobs: [
    {"*/5 * * * *", {Codrift.Integration.Sync, :run, []}}
  ]

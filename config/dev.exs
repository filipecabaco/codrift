import Config

config :francis, dev: true
config :codrift, bandit_opts: [port: 7437]

config :codrift, Codrift.Scheduler,
  jobs: [
    {"*/5 * * * *", {Codrift.Integration.Sync, :run, []}}
  ]

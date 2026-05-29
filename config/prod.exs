import Config

config :francis, dev: false

config :codrift, Codrift.Scheduler,
  jobs: [
    {"*/5 * * * *", {Codrift.Integration.Sync, :run, []}}
  ]

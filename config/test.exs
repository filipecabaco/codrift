import Config

config :codrift, bandit_opts: [port: 0]

# Keep test output readable — Francis/Bandit log every request at :info.
config :logger, level: :warning

# Disable the loopback/origin guard by default so the bulk of the HTTP tests can
# use Plug.Test's default host. Codrift.Web.LocalGuardTest re-enables it to
# exercise the guard end-to-end through the real pipeline.
config :codrift, http_guard_enabled: false

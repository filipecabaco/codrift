# capture_log: several tests exercise failure paths that log by design (integration
# sync against an unknown service, a corrupt initiatives.json, worktrees on
# non-repos). Captured logs are still printed for whichever test fails.
ExUnit.start(capture_log: true)

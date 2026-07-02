import Config

# In the test environment, point Codrift's persistence roots at a throwaway
# sandbox instead of the user's real home. Every persistence path derives from
# `Codrift.Paths.data_dir/0` / `config_dir/0` (Initiative.Store → ~/.config/codrift,
# Memory / OAuth / integration / SessionStore → ~/.codrift). Without this,
# `mix test` writes real `test-init` initiatives and context dirs into the
# user's actual home.
#
# This runs during Mix's runtime-config phase, which precedes `Codrift.start/2`,
# so the global Store reads the (freshly cleaned) sandbox when it initialises —
# `test_helper.exs` runs too late, after the app has already booted.
if config_env() == :test do
  sandbox = Path.join(System.tmp_dir!(), "codrift-test-home")
  File.rm_rf!(sandbox)
  File.mkdir_p!(sandbox)

  config :codrift,
    data_dir: Path.join(sandbox, ".codrift"),
    config_dir: Path.join(sandbox, ".config/codrift")
end

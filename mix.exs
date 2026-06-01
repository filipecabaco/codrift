defmodule Codrift.MixProject do
  use Mix.Project

  def project do
    [
      app: :codrift,
      version: "0.0.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix]
      ]
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  def application do
    [mod: {Codrift, []}, extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  @cli_commands ~w(tui mcp initiative session memory integration update)

  defp releases do
    [
      codrift: [
        include_erts: true,
        strip_beams: true,
        steps: [:assemble, &add_cli_commands/1, :tar]
      ]
    ]
  end

  defp add_cli_commands(release) do
    bin_path = Path.join([release.path, "bin", to_string(release.name)])
    content = File.read!(bin_path)

    no_args_case =
      "  \"\")\n    exec \"$RELEASE_ROOT/bin/codrift\" eval 'Codrift.CLI.Main.run([])'\n    ;;"

    cases =
      Enum.map_join(@cli_commands, "\n\n", fn cmd ->
        "  #{cmd})\n    shift\n    exec \"$RELEASE_ROOT/bin/codrift\" eval " <>
          "'Codrift.CLI.Main.run([\"#{cmd}\" | System.argv()])' \"$@\"\n    ;;"
      end)

    File.write!(
      bin_path,
      String.replace(content, "\n  *)\n", "\n\n#{no_args_case}\n\n#{cases}\n\n  *)\n",
        global: false
      )
    )

    release
  end

  defp deps do
    [
      {:francis, "~> 0.2"},
      {:req, "~> 0.5"},
      {:ex_ratatui,
       github: "filipecabaco/ex_ratatui",
       ref: "3784823fff0356c560c6d75c78b600cc64c1bf9e",
       override: true},
      {:erlexec, "~> 2.0"},
      {:exqlite, "~> 0.23"},
      {:quantum, "~> 3.0"},
      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end
end

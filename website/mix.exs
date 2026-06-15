defmodule Website.MixProject do
  use Mix.Project

  def project do
    [
      app: :website,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [mod: {Website, []}, extra_applications: [:logger]]
  end

  defp aliases do
    [
      "assets.build": ["tailwind default", "francis.digest priv/static --clean"]
    ]
  end

  defp deps do
    [
      {:francis, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:tailwind, "~> 0.4", runtime: Mix.env() == :dev}
    ]
  end
end

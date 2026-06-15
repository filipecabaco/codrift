import Config

config :website, port: 4001

config :francis, watcher: true

config :tailwind,
  version: "4.1.12",
  default: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/tw.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

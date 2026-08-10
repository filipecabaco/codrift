defmodule Website do
  use Francis,
    static: [at: "/", from: "priv/static"],
    bandit_opts: [
      port: 4001,
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      thousand_island_options: [transport_options: [:inet6]]
    ]

  @site_url "https://codrift.app"

  get("/", fn conn ->
    html =
      :code.priv_dir(:website)
      |> Path.join("templates/index.html.eex")
      |> EEx.eval_file(
        tw_css: Francis.Static.static_path("tw.css"),
        site_url: @site_url,
        og_image: Francis.Static.static_path("og.png", @site_url),
        version: Website.Version.current()
      )

    html(conn, html)
  end)

  unmatched(fn _ -> "not found" end)
end

defmodule Website do
  use Francis,
    static: [at: "/", from: "priv/static"],
    bandit_opts: [port: 4001]

  get("/", fn conn ->
    html =
      :code.priv_dir(:website)
      |> Path.join("templates/index.html.eex")
      |> EEx.eval_file(tw_css: Francis.Static.static_path("tw.css"))

    html(conn, html)
  end)

  unmatched(fn _ -> "not found" end)
end

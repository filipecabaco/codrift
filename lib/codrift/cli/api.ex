defmodule Codrift.CLI.API do
  @moduledoc """
  Reaching the *running* desktop app from a short-lived CLI process.

  Most `codrift` subcommands read and write files, so they can do their work in
  the `eval` process the boot script spawns. A few cannot: opening a pane or a
  file puts something in front of the user, and there is no user without a
  window. Those commands go over the local HTTP API instead — the same
  `POST /api/rpc` the web UI uses — so the app that owns the window does the
  work.

  Import it rather than aliasing, so call sites read `rpc("open_file", args)`:

      import Codrift.CLI.API
  """

  @default_port 43_117

  @doc """
  Calls a `Codrift.Core` operation on the running app.

  Returns `{:ok, result}` or `{:error, message}` — the message is already
  phrased for a human, including the one every caller hits first: the app not
  being open at all.
  """
  @spec rpc(String.t(), map()) :: {:ok, term()} | {:error, String.t()}
  def rpc(name, args) do
    # The release runs CLI commands through `eval`, which starts no applications
    # — Req's Finch pool included, and without it the first request dies on an
    # "unknown registry" that says nothing about what went wrong.
    {:ok, _} = Application.ensure_all_started(:req)

    url = "http://localhost:#{configured_port()}/api/rpc"

    # State-changing calls are rejected by Codrift.Plugs.LocalGuard without the
    # local token — the same one `codrift mcp install` embeds in registrations.
    headers = [{"x-codrift-token", Codrift.AuthToken.fetch()}]

    case Req.post(url, json: %{name: name, args: args}, headers: headers, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"ok" => result}}} ->
        {:ok, result}

      {:ok, %{status: _, body: %{"error" => message}}} ->
        {:error, message}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, %{reason: :econnrefused}} ->
        {:error,
         "The Codrift desktop app must be running for this command — it acts on " <>
           "the window. Launch it with `codrift start`, then run this again."}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Folds `--name=value` out of `argv` into `args`, if it is there.

  Absent flags are left out entirely rather than sent as `null`, so the server's
  own defaults still apply — a dropped flag has to look like "not passed", not
  like "passed as nothing".
  """
  @spec flag(map(), [String.t()], String.t()) :: map()
  def flag(args, argv, name) do
    prefix = "--#{name}="

    case Enum.find(argv, &String.starts_with?(&1, prefix)) do
      nil -> args
      found -> Map.put(args, name, String.slice(found, String.length(prefix)..-1//1))
    end
  end

  @doc "The port the app is serving on — 43117 unless configured otherwise."
  @spec configured_port() :: pos_integer()
  def configured_port do
    case Application.get_env(:codrift, :bandit_opts, [])[:port] do
      port when is_integer(port) and port > 0 -> port
      _ -> @default_port
    end
  end
end

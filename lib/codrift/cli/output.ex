defmodule Codrift.CLI.Output do
  @moduledoc """
  The one thing every `codrift` subcommand agrees on: what it puts on stdout.

  These commands are read by agents, not people — an agent runs `codrift memory
  search …` and parses the result — so the contract is *one JSON document on
  stdout, errors on stderr, a non-zero exit for a failure*. It was previously
  restated in six modules, which is six chances for one of them to drift into
  printing a log line alongside the document, or an error onto stdout where it
  would be parsed as the answer.

  Import it rather than aliasing, so call sites stay `print_json(...)`:

      import Codrift.CLI.Output
  """

  @doc "Writes `data` to stdout as a single JSON document."
  @spec print_json(term()) :: :ok
  def print_json(data), do: IO.puts(JSON.encode!(data))

  @doc """
  Reports `reason` on stderr as JSON and exits non-zero.

  `to_string/1` rather than requiring a binary: callers pass exception
  messages and atoms as readily as strings, and a `Protocol.UndefinedError`
  raised while reporting an error is the worst possible time for one.

  This never returns, which is why no test in this repo drives a path that
  reaches it — `System.halt/1` would take the test VM with it.
  """
  @spec fail(term()) :: no_return()
  def fail(reason) do
    IO.puts(:stderr, JSON.encode!(%{error: to_string(reason)}))
    System.halt(1)
  end
end

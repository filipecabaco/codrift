defmodule Codrift.Paths do
  @moduledoc "Shared path utilities used across the web UI, agents, and stores."

  @doc """
  Root for Codrift's mutable state (initiative context folders, memory DBs,
  OAuth tokens, the session DB). Defaults to `~/.codrift`; overridable via
  `config :codrift, :data_dir` so tests can redirect it to a sandbox.
  """
  def data_dir do
    case Application.get_env(:codrift, :data_dir) do
      nil -> Path.expand("~/.codrift")
      dir -> dir
    end
  end

  @doc """
  Root for Codrift's config-style state (the initiatives registry). Defaults to
  `~/.config/codrift`; overridable via `config :codrift, :config_dir`.
  """
  def config_dir do
    case Application.get_env(:codrift, :config_dir) do
      nil -> Path.expand("~/.config/codrift")
      dir -> dir
    end
  end

  @doc "Path to an initiative's context folder under `data_dir/initiatives/`."
  def initiative_dir(id), do: Path.join([data_dir(), "initiatives", id])

  @doc "Base folder holding every initiative's context folder."
  def initiatives_base, do: Path.join(data_dir(), "initiatives")

  @doc """
  Append-only transcript log for an agent, under its initiative's context
  folder. Dot-prefixed so it is never picked up as an initiative context file,
  and removed together with the context folder when the initiative is deleted.
  """
  def agent_log(initiative_id, agent_id),
    do: Path.join([initiative_dir(initiative_id), ".agent-logs", "#{agent_id}.log"])

  @doc """
  Replaces the user's home directory prefix with `~`.

  Returns the path unchanged when it does not live under the home directory.

      iex> Codrift.Paths.compact(Path.expand("~/foo/bar"))
      "~/foo/bar"
  """
  def compact(path) do
    home = Path.expand("~")
    relative = Path.relative_to(path, home)
    if relative == path, do: path, else: "~/#{relative}"
  end
end

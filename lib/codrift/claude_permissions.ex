defmodule Codrift.ClaudePermissions do
  @moduledoc """
  Pure functions for managing Claude Code permission rules in `.claude/settings.json`
  within a project directory.

  Each project directory that Claude Code works in can have its own
  `.claude/settings.json`. Adding `"Read"` to `permissions.allow` in that file
  means agents running there will never be prompted to confirm file reads.
  """

  @doc """
  Adds `rule` to `permissions.allow` in `{dir}/.claude/settings.json`.

  Idempotent — if the rule is already present the file is unchanged.
  Creates the file and the `.claude/` directory if they do not exist.
  Returns the updated allow list.
  """
  def add(dir, rule) do
    if not File.dir?(dir) do
      []
    else
      path = settings_path(dir)
      settings = read(path)
      allow = get_in(settings, ["permissions", "allow"]) || []

      if rule in allow do
        allow
      else
        updated_allow = [rule | allow]
        write(path, set_allow(settings, updated_allow))
        updated_allow
      end
    end
  end

  @doc """
  Removes `rule` from `permissions.allow` in `{dir}/.claude/settings.json`.

  No-op if the rule was not present. Returns the updated allow list.
  """
  def remove(dir, rule) do
    path = settings_path(dir)
    settings = read(path)
    allow = get_in(settings, ["permissions", "allow"]) || []
    updated_allow = List.delete(allow, rule)

    if updated_allow == allow do
      allow
    else
      write(path, set_allow(settings, updated_allow))
      updated_allow
    end
  end

  @doc "Returns the current `permissions.allow` list for `dir`, or `[]` if none is set."
  def allow_list(dir) do
    get_in(read(settings_path(dir)), ["permissions", "allow"]) || []
  end

  defp set_allow(settings, allow) do
    permissions = Map.get(settings, "permissions", %{})
    Map.put(settings, "permissions", Map.put(permissions, "allow", allow))
  end

  defp settings_path(dir), do: Path.join([dir, ".claude", "settings.json"])

  defp read(path) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, map} <- JSON.decode(content) do
      map
    else
      _ -> %{}
    end
  end

  defp write(path, settings) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, JSON.encode!(settings))
  end
end

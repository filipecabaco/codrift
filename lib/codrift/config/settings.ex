defmodule Codrift.Config.Settings do
  @moduledoc """
  Reads and writes `~/.codrift/settings.json`.

  Tracks per-adapter start counts (used to sort the agent picker) and the
  user's **launch profiles** — named bindings of a base adapter plus env
  overrides, so the same tool can run under different accounts/config folders
  (e.g. `claude-personal` vs `claude-work` via distinct `CLAUDE_CONFIG_DIR`s).

  Profiles are stored under the `"profiles"` key, keyed by name. The optional
  `"command"` replaces the adapter's own executable, so a profile can point at
  a wrapper script or a second install rather than the one on `PATH`, and the
  optional `"args"` are appended to the adapter's own arguments:

      {
        "default_agent": "claude-work",
        "profiles": {
          "claude-work":     { "adapter": "claude", "command": "claude-work", "args": ["--model", "opus"], "env": { "CLAUDE_CONFIG_DIR": "~/.claude-work" } },
          "claude-personal": { "adapter": "claude", "env": { "CLAUDE_CONFIG_DIR": "~/.claude-personal" } }
        }
      }
  """

  defp path, do: Path.join(Codrift.Paths.data_dir(), "settings.json")

  @doc ~S(Returns all launch profiles as `name => %{"adapter" => name, "env" => map}`.)
  def profiles do
    read() |> Map.get("profiles", %{})
  end

  @doc "Fetches one launch profile by name, or `{:error, :not_found}`."
  def profile(name) do
    case Map.fetch(profiles(), name) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Creates or replaces a launch profile.

  `attrs` takes `:adapter`, and optionally `:command`, `:args` and `:env`. The
  whole profile is rewritten, so clearing any of them removes it from disk.
  Values are stored verbatim: `~` is expanded at launch, not here, so the file
  stays readable and portable.
  """
  def put_profile(name, %{adapter: adapter} = attrs)
      when is_binary(name) and is_binary(adapter) do
    settings = read()
    profiles = Map.get(settings, "profiles", %{})

    profile =
      %{"adapter" => adapter, "env" => Map.get(attrs, :env) || %{}}
      |> put_unless_empty("command", Map.get(attrs, :command))
      |> put_unless_empty("args", Map.get(attrs, :args))

    write(Map.put(settings, "profiles", Map.put(profiles, name, profile)))
  end

  defp put_unless_empty(profile, _key, value) when value in [nil, "", []], do: profile
  defp put_unless_empty(profile, key, value), do: Map.put(profile, key, value)

  @doc "Removes a launch profile, or `{:error, :not_found}` if there was none."
  def delete_profile(name) when is_binary(name) do
    settings = read()
    profiles = Map.get(settings, "profiles", %{})

    case Map.pop(profiles, name) do
      {nil, _} ->
        {:error, :not_found}

      {_removed, rest} ->
        write(Map.put(settings, "profiles", rest))
        :ok
    end
  end

  @doc """
  Returns the launch choice new initiatives start from — a base adapter name or
  a profile name — or `nil` when the user has never picked one.
  """
  def default_agent, do: read() |> Map.get("default_agent")

  @doc "Remembers the launch choice to seed new initiatives with."
  def put_default_agent(choice) when is_binary(choice) do
    write(Map.put(read(), "default_agent", choice))
  end

  @doc "Returns a map of adapter name → start count."
  def adapter_start_counts do
    read() |> Map.get("adapter_starts", %{})
  end

  @doc ~S(Returns the selected UI theme id, or `nil` when the user never picked one.)
  def theme, do: read() |> Map.get("theme")

  @doc "Remembers the selected UI theme id."
  def put_theme(name) when is_binary(name) do
    write(Map.put(read(), "theme", name))
  end

  @doc """
  Returns the selected typeface as `%{"family" => name | nil, "size" => px | nil}`.

  Both are `nil` until the user picks; the UI then falls back to the platform's
  default monospace.
  """
  def font do
    stored = read() |> Map.get("font", %{})
    %{"family" => Map.get(stored, "family"), "size" => Map.get(stored, "size")}
  end

  @doc "Remembers the selected typeface."
  def put_font(family, size) when is_binary(family) and is_integer(size) do
    write(Map.put(read(), "font", %{"family" => family, "size" => size}))
  end

  @doc "Increments the start count for the given adapter module."
  def increment_adapter_start(adapter) do
    name = Codrift.Agent.adapter_name(adapter)
    settings = read()
    counts = Map.get(settings, "adapter_starts", %{})
    write(Map.put(settings, "adapter_starts", Map.update(counts, name, 1, &(&1 + 1))))
  end

  defp read do
    case File.read(path()) do
      {:ok, content} -> JSON.decode!(content)
      {:error, _} -> %{}
    end
  end

  defp write(data) do
    path = path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(data))
  end
end

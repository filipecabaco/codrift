defmodule Codrift.Config.KeybindingsTest do
  @moduledoc """
  `string_to_action/1` is a wall of one-line clauses, one per action, and a
  missing clause fails *silently*: the override is dropped and the user keeps
  the default, with nothing logged. That is the failure this file exists to
  catch, so every action is round-tripped rather than a representative few.

  Not `async` — it writes the single sandbox `keybindings.json`.
  """
  use ExUnit.Case, async: false

  alias Codrift.Config.Keybindings

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:codrift, :data_dir)
    Application.put_env(:codrift, :data_dir, tmp_dir)
    on_exit(fn -> Application.put_env(:codrift, :data_dir, previous) end)
    :ok
  end

  defp write!(map) do
    File.write!(Path.join(Codrift.Paths.data_dir(), "keybindings.json"), JSON.encode!(map))
  end

  test "defaults/0 binds every action exactly once" do
    specs = Keybindings.defaults() |> Map.values()

    assert specs == Enum.uniq(specs),
           "two actions share a key: #{inspect(specs -- Enum.uniq(specs))}"
  end

  test "load/0 returns the defaults when there is no file" do
    assert Keybindings.load() == Keybindings.defaults()
  end

  test "every default action can be overridden by name" do
    # One file, every action remapped to a spec that could not collide with a
    # real binding, so a dropped clause shows up as a value that stayed put.
    overrides =
      Keybindings.defaults()
      |> Map.keys()
      |> Enum.with_index()
      |> Map.new(fn {action, i} -> {Atom.to_string(action), "alt+#{i}"} end)

    write!(overrides)
    loaded = Keybindings.load()

    for {name, spec} <- overrides do
      action = String.to_existing_atom(name)

      assert loaded[action] == spec,
             "#{name} was not applied — `string_to_action/1` is probably missing its clause"
    end
  end

  test "the git actions and the settings/agent commands are bound out of the box" do
    defaults = Keybindings.defaults()

    assert defaults[:git_fetch] == "f"
    assert defaults[:git_rebase] == "g"
    assert defaults[:git_commit] == "m"
    assert defaults[:git_push] == "u"
    assert defaults[:initiative_agent] == "p"
    assert defaults[:settings] == "ctrl+,"
  end

  test "an unknown action name is ignored rather than added to the map" do
    write!(%{"not_an_action" => "z", "refresh" => "F5"})
    loaded = Keybindings.load()

    refute Map.has_key?(loaded, :not_an_action)
    assert loaded[:refresh] == "F5"
  end

  test "a non-string spec is ignored, leaving that action on its default" do
    write!(%{"refresh" => 42, "quit" => ["ctrl", "q"]})
    loaded = Keybindings.load()

    assert loaded[:refresh] == Keybindings.defaults()[:refresh]
    assert loaded[:quit] == Keybindings.defaults()[:quit]
  end

  test "unparseable JSON falls back to the defaults instead of crashing the app" do
    File.write!(Path.join(Codrift.Paths.data_dir(), "keybindings.json"), "{not json")
    assert Keybindings.load() == Keybindings.defaults()
  end

  test "an override leaves every action it does not name untouched" do
    write!(%{"navigate_down" => "ctrl+j"})
    loaded = Keybindings.load()

    assert loaded[:navigate_down] == "ctrl+j"
    assert map_size(loaded) == map_size(Keybindings.defaults())

    for {action, spec} <- Keybindings.defaults(), action != :navigate_down do
      assert loaded[action] == spec
    end
  end
end

defmodule Codrift.ThemesTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:codrift, :data_dir)
    Application.put_env(:codrift, :data_dir, tmp_dir)
    on_exit(fn -> Application.put_env(:codrift, :data_dir, previous) end)
    File.mkdir_p!(Path.join(tmp_dir, "themes"))
    :ok
  end

  defp write_theme!(name, content) do
    File.write!(Path.join([Codrift.Paths.data_dir(), "themes", name]), content)
  end

  describe "list/0" do
    test "is empty when no themes folder exists", %{tmp_dir: tmp_dir} do
      File.rm_rf!(Path.join(tmp_dir, "themes"))
      assert Codrift.Themes.list() == []
    end

    test "lists only json files, sorted" do
      write_theme!("zed.json", ~s({"colors":{}}))
      write_theme!("aurora.json", ~s({"colors":{}}))
      write_theme!("notes.txt", "ignore me")

      assert Codrift.Themes.list() == ["aurora.json", "zed.json"]
    end
  end

  describe "read/1" do
    test "returns a decoded VS Code theme" do
      write_theme!(
        "night.json",
        ~s({"name":"Night","type":"dark","colors":{"editor.background":"#101015"}})
      )

      assert {:ok, %{"type" => "dark", "colors" => %{"editor.background" => "#101015"}}} =
               Codrift.Themes.read("night.json")
    end

    test "rejects a name that escapes the themes folder" do
      for name <- ["../settings.json", "/etc/passwd", "sub/dir.json", "theme.js"] do
        assert {:error, :not_found} = Codrift.Themes.read(name)
      end
    end

    test "reports an unknown file as not found" do
      assert {:error, :not_found} = Codrift.Themes.read("missing.json")
    end

    test "reports malformed json and non-themes as invalid" do
      write_theme!("broken.json", "{not json")
      write_theme!("plain.json", ~s({"name":"no colours here"}))

      assert {:error, :invalid} = Codrift.Themes.read("broken.json")
      assert {:error, :invalid} = Codrift.Themes.read("plain.json")
    end
  end

  describe "Core theme operations" do
    test "round-trips the selected theme and lists drop-ins" do
      write_theme!("night.json", ~s({"colors":{"editor.background":"#101015"}}))

      assert {:ok, %{"name" => nil}} = Codrift.Core.call("get_theme", %{})

      assert {:ok, %{"name" => "dracula"}} =
               Codrift.Core.call("set_theme", %{"name" => "dracula"})

      assert {:ok, %{"name" => "dracula"}} = Codrift.Core.call("get_theme", %{})
      assert {:ok, %{"themes" => ["night.json"]}} = Codrift.Core.call("list_themes", %{})

      assert {:ok, %{"colors" => %{"editor.background" => "#101015"}}} =
               Codrift.Core.call("read_theme", %{"name" => "night.json"})

      assert {:error, msg} = Codrift.Core.call("read_theme", %{"name" => "nope.json"})
      assert msg =~ "theme not found"
    end

    test "round-trips the selected font and clamps a hand-edited size" do
      assert {:ok, %{"family" => nil, "size" => nil}} = Codrift.Core.call("get_font", %{})

      assert {:ok, %{"family" => "JetBrains Mono", "size" => 15}} =
               Codrift.Core.call("set_font", %{"family" => "JetBrains Mono", "size" => 15})

      assert {:ok, %{"family" => "JetBrains Mono", "size" => 15}} =
               Codrift.Core.call("get_font", %{})

      # settings.json is hand-editable; a 400px interface is not reachable.
      assert {:ok, %{"size" => 20}} =
               Codrift.Core.call("set_font", %{"family" => "Hack", "size" => 400})

      assert {:ok, %{"size" => 10}} =
               Codrift.Core.call("set_font", %{"family" => "Hack", "size" => 2})
    end

    test "round-trips the sidebar sort and refuses one it does not know" do
      # Oldest-first is the order the list has always had, so an install that
      # never chose reads back as `created` rather than as nothing.
      assert {:ok, %{"sort" => "created"}} = Codrift.Core.call("get_sidebar_sort", %{})

      for sort <- ~w(recent name status created) do
        assert {:ok, %{"sort" => ^sort}} =
                 Codrift.Core.call("set_sidebar_sort", %{"sort" => sort})

        assert {:ok, %{"sort" => ^sort}} = Codrift.Core.call("get_sidebar_sort", %{})
      end

      assert {:error, msg} = Codrift.Core.call("set_sidebar_sort", %{"sort" => "by-vibes"})
      assert msg =~ "invalid sort"
      # The rejected value must not have been written on the way out.
      assert {:ok, %{"sort" => "created"}} = Codrift.Core.call("get_sidebar_sort", %{})
    end
  end
end

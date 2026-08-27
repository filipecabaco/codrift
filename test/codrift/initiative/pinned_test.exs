defmodule Codrift.Initiative.PinnedTest do
  @moduledoc """
  Files of interest, as links in the context folder.

  The contract worth pinning down is the containment one: a pin is a link the
  *reader* follows back out of the context folder, so anything accepted here is
  something `read_context_file` is then obliged to serve.
  """
  use ExUnit.Case, async: true

  alias Codrift.Initiative.Pinned

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    context = Path.join(tmp, "context")
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.mkdir_p!(context)
    File.write!(Path.join(context, "initiative.md"), "# Initiative")
    {:ok, context: context, repo: repo}
  end

  defp write!(dir, rel, content \\ "x") do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "pin/4" do
    test "links the file into the context folder under its own name", ctx do
      target = write!(ctx.repo, "lib/router.ex")

      assert {:ok, pin} = Pinned.pin(ctx.context, [ctx.repo], target)
      assert pin["name"] == "router.ex"
      refute pin["existing"]
      assert {:ok, ^target} = File.read_link(Path.join(ctx.context, "router.ex"))
    end

    # The pin has to read back through the same door the UI uses, or it is a row
    # in the sidebar that errors when clicked.
    test "the link is readable as a context file", ctx do
      target = write!(ctx.repo, "lib/router.ex", "defmodule Router do end")
      {:ok, pin} = Pinned.pin(ctx.context, [ctx.repo], target)

      assert {:ok, "defmodule Router do end"} =
               Codrift.Files.read_within(
                 [ctx.context, ctx.repo],
                 Path.join(ctx.context, pin["name"])
               )
    end

    # A copy would go stale the first time an agent edited the file.
    test "reads back edited content, because it is a link and not a copy", ctx do
      target = write!(ctx.repo, "lib/router.ex", "before")
      {:ok, pin} = Pinned.pin(ctx.context, [ctx.repo], target)
      File.write!(target, "after")

      assert {:ok, "after"} =
               Codrift.Files.read_within(
                 [ctx.context, ctx.repo],
                 Path.join(ctx.context, pin["name"])
               )
    end

    test "pinning the same file twice makes one link, not two", ctx do
      target = write!(ctx.repo, "lib/router.ex")

      assert {:ok, %{"name" => name, "existing" => false}} =
               Pinned.pin(ctx.context, [ctx.repo], target)

      assert {:ok, %{"name" => ^name, "existing" => true}} =
               Pinned.pin(ctx.context, [ctx.repo], target)

      assert Path.wildcard(Path.join(ctx.context, "router.ex*")) |> length() == 1
    end

    # Two repos in one initiative each have a mix.exs; the second must not be
    # silently dropped or, worse, take over the first one's name.
    test "disambiguates a name already taken by a different file", ctx do
      other = Path.join(ctx.tmp_dir, "other")
      first = write!(ctx.repo, "mix.exs", "first")
      second = write!(other, "mix.exs", "second")

      assert {:ok, %{"name" => "mix.exs"}} = Pinned.pin(ctx.context, [ctx.repo, other], first)
      assert {:ok, %{"name" => second_name}} = Pinned.pin(ctx.context, [ctx.repo, other], second)

      assert second_name == "other-mix.exs"
      assert {:ok, ^second} = File.read_link(Path.join(ctx.context, second_name))
    end

    test "refuses a file outside every one of the initiative's directories", ctx do
      outside = write!(Path.join(ctx.tmp_dir, "elsewhere"), "secrets.env")

      assert {:error, :forbidden} = Pinned.pin(ctx.context, [ctx.repo], outside)
    end

    # Containment is checked after symlinks are resolved, or a link inside an
    # allowed directory would be a way to pin anything on the machine.
    test "refuses a symlink inside the repo that points outside it", ctx do
      outside = write!(Path.join(ctx.tmp_dir, "elsewhere"), "secrets.env")
      bait = Path.join(ctx.repo, "innocent.ex")
      File.ln_s!(outside, bait)

      assert {:error, :forbidden} = Pinned.pin(ctx.context, [ctx.repo], bait)
    end

    test "refuses a directory and a path that is not there", ctx do
      assert {:error, :not_a_file} =
               Pinned.pin(ctx.context, [ctx.repo], Path.join(ctx.repo, "lib"))

      assert {:error, :not_a_file} =
               Pinned.pin(ctx.context, [ctx.repo], Path.join(ctx.repo, "no"))
    end

    # The context folder's real documents are not pinnable ground.
    test "never replaces a real context document", ctx do
      target = write!(ctx.repo, "initiative.md", "not the initiative doc")

      assert {:ok, %{"name" => name}} = Pinned.pin(ctx.context, [ctx.repo], target)
      assert name == "repo-initiative.md"
      assert File.read!(Path.join(ctx.context, "initiative.md")) == "# Initiative"
    end

    test "an explicit name that collides is refused rather than honoured", ctx do
      target = write!(ctx.repo, "lib/router.ex")

      assert {:error, :reserved} =
               Pinned.pin(ctx.context, [ctx.repo], target, "initiative.md")
    end

    # A name is a name, not a path: a pin must not be a way to write below the
    # context folder.
    test "strips any directory from an explicit name", ctx do
      target = write!(ctx.repo, "lib/router.ex")

      assert {:ok, %{"name" => "escaped.ex"}} =
               Pinned.pin(ctx.context, [ctx.repo], target, "../../escaped.ex")

      assert File.exists?(Path.join(ctx.context, "escaped.ex"))
    end
  end

  describe "list/1" do
    test "returns the pins and ignores the real documents", ctx do
      target = write!(ctx.repo, "lib/router.ex")
      {:ok, _} = Pinned.pin(ctx.context, [ctx.repo], target)

      assert Pinned.list(ctx.context) == %{"router.ex" => target}
    end
  end
end

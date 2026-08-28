defmodule Codrift.Initiative.Pinned do
  @moduledoc """
  Files of interest: a symlink in an initiative's context folder pointing at a
  file inside one of the initiative's directories.

  ## Why a symlink and not a list

  An initiative's context folder is already the place where "what this work is
  about" lives, and everything that lands in it is on offer everywhere at once —
  the sidebar lists it, the Context pane opens it, `list_context_files` returns
  it, and an agent that `ls`es the folder sees it. A registry in a JSON file
  would have needed every one of those to learn about it; a symlink is a file,
  so all of them already work.

  It also survives the thing a copy would not: the target keeps changing. A
  pinned source file that an agent then edits reads back edited, because there
  is only ever one copy of it.

  ## What may be pinned

  Only a regular file that resolves — symlinks followed — inside one of the
  initiative's own directories. That is the same containment rule `read_file`
  enforces, and it has to hold here too: a pin is a link the *reader* will later
  follow out of the context folder, so anything this accepts is something
  `read_context_file` is then obliged to serve.
  """

  alias Codrift.Files

  @doc """
  Links `path` into `context_dir`, and returns the name it was filed under.

  `name` overrides the link name; without one the file's own basename is used,
  disambiguated with its parent directory when that name is taken by something
  else (two `mix.exs` from two repos are the reason this is not just a basename).

  Pinning the same file twice is not an error and does not make a second link —
  the existing name comes back with `"existing" => true`, so an agent can call
  this every time it touches a file without turning the folder into a pile.

  Returns `{:error, reason}` for `:not_a_file`, `:forbidden` (outside the
  initiative), `:reserved` (the name is a real context document — pinning must
  never be able to replace `initiative.md`), or a posix error.
  """
  @spec pin(String.t(), [String.t()], String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def pin(context_dir, allowed_dirs, path, name \\ nil) do
    with {:ok, target} <- resolve(allowed_dirs, path),
         {:ok, link_name} <- choose_name(context_dir, target, name),
         {:ok, outcome} <- link(context_dir, link_name, target) do
      {:ok,
       %{
         "name" => link_name,
         "path" => target,
         "link" => Path.join(context_dir, link_name),
         "existing" => outcome == :existing
       }}
    end
  end

  @doc """
  The absolute target of every pin in `context_dir`, keyed by link name.

  Reads the links rather than a manifest, for the same reason `pin/4` writes
  them: the folder is the record.
  """
  @spec list(String.t()) :: %{String.t() => String.t()}
  def list(context_dir) do
    case File.ls(context_dir) do
      {:ok, names} -> names |> Enum.flat_map(&target_of(context_dir, &1)) |> Map.new()
      {:error, _} -> %{}
    end
  end

  # A list rather than a value so `flat_map` drops the real documents: only a
  # symlink is a pin.
  defp target_of(context_dir, name) do
    case File.read_link(Path.join(context_dir, name)) do
      {:ok, target} -> [{name, Path.expand(target, context_dir)}]
      {:error, _} -> []
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp resolve(allowed_dirs, path) do
    expanded = path |> Files.expand_user() |> Path.expand()

    with {:ok, real} <- Files.realpath(expanded),
         true <- File.regular?(real) do
      if Enum.any?(allowed_dirs, &contains?(&1, real)),
        do: {:ok, real},
        else: {:error, :forbidden}
    else
      false -> {:error, :not_a_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp contains?(dir, path) do
    case Files.realpath(dir) do
      {:ok, base} ->
        path == base or String.starts_with?(path, String.trim_trailing(base, "/") <> "/")

      _ ->
        false
    end
  end

  # An explicit name is taken as given (minus any path it carries — a pin is a
  # file *in* the context folder, never a way to write somewhere below it).
  defp choose_name(context_dir, target, name) when is_binary(name) and name != "" do
    candidate = Path.basename(name)
    if available?(context_dir, candidate, target), do: {:ok, candidate}, else: {:error, :reserved}
  end

  defp choose_name(context_dir, target, _name) do
    base = Path.basename(target)
    parent = target |> Path.dirname() |> Path.basename()

    [base, "#{parent}-#{base}"]
    |> Enum.concat(Enum.map(2..9, &"#{&1}-#{base}"))
    |> Enum.find(&available?(context_dir, &1, target))
    |> case do
      nil -> {:error, :reserved}
      chosen -> {:ok, chosen}
    end
  end

  # Free, or already our own link to the same file. Deliberately not "free, or
  # any symlink": re-pointing an existing pin at a different file would silently
  # change what an initiative document refers to. `lstat`, not `exists?`, so a
  # pin whose target has since been deleted still counts as occupied rather than
  # being quietly reused for something else.
  defp available?(context_dir, name, target) do
    linked?(context_dir, name, target) or
      match?({:error, :enoent}, File.lstat(Path.join(context_dir, name)))
  end

  defp linked?(context_dir, name, target) do
    case File.read_link(Path.join(context_dir, name)) do
      {:ok, existing} -> Path.expand(existing, context_dir) == target
      _ -> false
    end
  end

  # `:existing` is what makes pinning idempotent, and the caller reports it —
  # an agent pinning the same file on every touch should not be told it created
  # something each time.
  defp link(context_dir, name, target) do
    if linked?(context_dir, name, target) do
      {:ok, :existing}
    else
      File.mkdir_p!(context_dir)

      case File.ln_s(target, Path.join(context_dir, name)) do
        :ok -> {:ok, :created}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

defmodule Codrift.Diff do
  @moduledoc """
  Pure module for generating and parsing git unified diffs.

  Call `generate/2` to shell out to `git diff` and get a list of `FileDiff`
  structs. Call `parse/1` to parse a raw patch string directly.
  """

  defmodule Line do
    @moduledoc false
    defstruct [:type, :content]
  end

  defmodule Hunk do
    @moduledoc false
    defstruct [:old_start, :old_count, :new_start, :new_count, :header, :lines]
  end

  defmodule FileDiff do
    @moduledoc false
    defstruct [:path, :old_path, :hunks, :additions, :deletions]
  end

  @doc "Serialises a `FileDiff` back to a unified diff patch string for display."
  def to_unified(%FileDiff{} = f) do
    header = "--- a/#{f.old_path}\n+++ b/#{f.path}"
    hunks = Enum.map_join(f.hunks, "\n", &hunk_to_unified/1)
    "#{header}\n#{hunks}"
  end

  defp hunk_to_unified(hunk) do
    lines =
      Enum.map_join(hunk.lines, "\n", fn
        %{type: :add, content: c} -> "+" <> c
        %{type: :remove, content: c} -> "-" <> c
        %{type: :context, content: c} -> " " <> c
      end)

    "#{hunk.header}\n#{lines}"
  end

  def to_map(%FileDiff{} = f) do
    %{
      "path" => f.path,
      "old_path" => f.old_path,
      "additions" => f.additions,
      "deletions" => f.deletions,
      "hunks" => Enum.map(f.hunks, &hunk_to_map/1)
    }
  end

  defp hunk_to_map(%Hunk{} = h) do
    %{
      "old_start" => h.old_start,
      "old_count" => h.old_count,
      "new_start" => h.new_start,
      "new_count" => h.new_count,
      "header" => h.header,
      "lines" => Enum.map(h.lines, &line_to_map/1)
    }
  end

  defp line_to_map(%Line{} = l) do
    %{"type" => Atom.to_string(l.type), "content" => l.content}
  end

  @doc """
  Generates a diff for the given directory.

  Options:
    - `:from` - base ref (default: index/working tree)
    - `:to` - target ref
    - `:staged` - boolean, diff staged changes (default: false)
    - `:paths` - list of paths to limit the diff
    - `:context` - context lines around changes (default: 3)
  """
  def generate(dir, opts \\ []) do
    args = build_args(opts)

    case System.cmd("git", args, cd: dir, stderr_to_stdout: false) do
      {output, status} when status in [0, 1] -> {:ok, parse(output)}
      {error, code} -> {:error, {code, error}}
    end
  end

  @doc "Parses a unified diff patch string into a list of FileDiff structs."
  def parse(patch) when is_binary(patch) do
    patch
    |> String.split("\n")
    |> parse_files([])
    |> Enum.reverse()
  end

  defp build_args(opts) do
    base = ["diff", "--patch", "-U#{opts[:context] || 3}"]
    base = if opts[:staged], do: base ++ ["--cached"], else: base
    base = if opts[:from], do: base ++ [opts[:from]], else: base
    base = if opts[:to], do: base ++ [opts[:to]], else: base
    paths = opts[:paths] || []
    if paths == [], do: base, else: base ++ ["--"] ++ paths
  end

  defp parse_files([], acc), do: acc

  defp parse_files([line | rest], acc) do
    if String.starts_with?(line, "diff --git ") do
      {file_diff, remaining} = parse_file([line | rest])
      parse_files(remaining, [file_diff | acc])
    else
      parse_files(rest, acc)
    end
  end

  defp parse_file(lines) do
    {header_lines, rest} = Enum.split_while(lines, &(!String.starts_with?(&1, "@@ ")))

    {old_path, new_path} = extract_paths(header_lines)

    {hunks, remaining} = parse_hunks(rest, [])

    {additions, deletions} = count_changes(hunks)

    file_diff = %FileDiff{
      path: new_path,
      old_path: old_path,
      hunks: hunks,
      additions: additions,
      deletions: deletions
    }

    {file_diff, remaining}
  end

  defp extract_paths(header_lines) do
    old_path =
      Enum.find_value(header_lines, fn line ->
        if String.starts_with?(line, "--- "), do: strip_path_prefix(line, "--- ")
      end)

    new_path =
      Enum.find_value(header_lines, fn line ->
        if String.starts_with?(line, "+++ "), do: strip_path_prefix(line, "+++ ")
      end)

    {old_path || "/dev/null", new_path || "/dev/null"}
  end

  defp strip_path_prefix(line, prefix) do
    line
    |> String.trim_leading(prefix)
    |> then(fn path ->
      if String.starts_with?(path, "a/") or String.starts_with?(path, "b/") do
        String.slice(path, 2..-1//1)
      else
        path
      end
    end)
  end

  defp parse_hunks([], acc), do: {Enum.reverse(acc), []}

  defp parse_hunks([line | rest] = lines, acc) do
    cond do
      String.starts_with?(line, "diff --git ") ->
        {Enum.reverse(acc), lines}

      String.starts_with?(line, "@@ ") ->
        {hunk, remaining} = parse_hunk([line | rest])
        parse_hunks(remaining, [hunk | acc])

      true ->
        parse_hunks(rest, acc)
    end
  end

  defp parse_hunk(["@@ " <> _ = header | rest]) do
    {old_start, old_count, new_start, new_count} = parse_hunk_header(header)

    {lines, remaining} =
      Enum.split_while(rest, fn line ->
        not (String.starts_with?(line, "@@ ") or String.starts_with?(line, "diff --git "))
      end)

    hunk_lines =
      lines
      |> Enum.reject(&(&1 == "\\ No newline at end of file"))
      |> Enum.map(&classify_line/1)

    hunk = %Hunk{
      old_start: old_start,
      old_count: old_count,
      new_start: new_start,
      new_count: new_count,
      header: header,
      lines: hunk_lines
    }

    {hunk, remaining}
  end

  @hunk_header_re ~r/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/
  defp parse_hunk_header(header) do
    case Regex.run(@hunk_header_re, header) do
      [_, os, oc, ns, nc] ->
        {String.to_integer(os), parse_count(oc), String.to_integer(ns), parse_count(nc)}

      [_, os, "", ns, ""] ->
        {String.to_integer(os), 1, String.to_integer(ns), 1}

      _ ->
        {0, 0, 0, 0}
    end
  end

  defp parse_count(""), do: 1
  defp parse_count(s), do: String.to_integer(s)

  defp classify_line("+" <> content), do: %Line{type: :add, content: content}
  defp classify_line("-" <> content), do: %Line{type: :remove, content: content}
  defp classify_line(" " <> content), do: %Line{type: :context, content: content}
  defp classify_line(content), do: %Line{type: :context, content: content}

  defp count_changes(hunks) do
    Enum.reduce(hunks, {0, 0}, fn hunk, {adds, dels} ->
      hunk_adds = Enum.count(hunk.lines, &(&1.type == :add))
      hunk_dels = Enum.count(hunk.lines, &(&1.type == :remove))
      {adds + hunk_adds, dels + hunk_dels}
    end)
  end
end

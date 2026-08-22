defmodule Codrift.Initiative.DirEntry do
  @moduledoc """
  A project directory entry within an initiative.

  Carries the source path and its optional git isolation. When a worktree is
  active, `worktree_path` is set and agents run there instead of the original
  source `path`. A `branch` is the lighter alternative: agents stay in `path`,
  which is checked out on an initiative-specific branch.
  """

  @enforce_keys [:path]
  defstruct [:path, worktree_enabled: false, worktree_path: nil, branch: nil]

  @type t :: %__MODULE__{
          path: String.t(),
          worktree_enabled: boolean(),
          worktree_path: String.t() | nil,
          branch: String.t() | nil
        }

  @doc "Creates a new entry from a source path and optional keyword opts."
  def new(path, opts \\ []) do
    %__MODULE__{
      path: path,
      worktree_enabled: Keyword.get(opts, :worktree_enabled, false),
      worktree_path: Keyword.get(opts, :worktree_path),
      branch: Keyword.get(opts, :branch)
    }
  end

  @doc "Returns the effective working directory: worktree path when active, otherwise source path."
  def effective_path(%__MODULE__{worktree_path: wp}) when is_binary(wp), do: wp
  def effective_path(%__MODULE__{path: p}), do: p

  @doc """
  The directory an agent asking for `path` should actually run in.

  A worktree exists precisely so agents do not touch the working copy, so asking
  for the source path has to land in the worktree — otherwise the isolation is
  created and then ignored, and the diff view (which already reads the worktree)
  ends up showing a checkout nothing is writing to while the agent edits the
  repository the user is sitting in.

  Everything else passes straight through: a path that is *already* the
  worktree, so re-resolving is idempotent, and any directory that is not one of
  the initiative's entries, which is how loose agents and MCP callers ask for
  somewhere specific.

  Only exact matches are mapped. A *subdirectory* of a worktree-backed entry is
  left alone on purpose: rewriting it would mean assuming the same relative path
  exists inside the checkout, and being wrong puts an agent somewhere nobody
  named.
  """
  @spec resolve(String.t(), [t()]) :: String.t()
  def resolve(path, entries) do
    expanded = Path.expand(path)

    case Enum.find(entries, &(&1.path == expanded)) do
      nil -> expanded
      entry -> effective_path(entry)
    end
  end

  @doc "Serialises to a plain map for JSON encoding."
  def to_map(%__MODULE__{} = e) do
    %{"path" => e.path, "worktree_enabled" => e.worktree_enabled}
    |> put_if("worktree_path", e.worktree_path)
    |> put_if("branch", e.branch)
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc """
  Deserialises from a JSON-decoded value.

  Accepts the legacy format (plain string path) for backwards compatibility
  with initiatives created before this field was introduced.
  """
  def from_value(path) when is_binary(path), do: %__MODULE__{path: path}

  def from_value(%{"path" => path} = m) do
    %__MODULE__{
      path: path,
      worktree_enabled: Map.get(m, "worktree_enabled", false),
      worktree_path: Map.get(m, "worktree_path"),
      branch: Map.get(m, "branch")
    }
  end
end

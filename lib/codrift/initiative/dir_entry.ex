defmodule Codrift.Initiative.DirEntry do
  @moduledoc """
  A project directory entry within an initiative.

  Carries the source path and optional git worktree configuration.
  When a worktree is active, `worktree_path` is set and agents run there
  instead of the original source `path`.
  """

  @enforce_keys [:path]
  defstruct [:path, worktree_enabled: false, worktree_path: nil]

  @type t :: %__MODULE__{
          path: String.t(),
          worktree_enabled: boolean(),
          worktree_path: String.t() | nil
        }

  @doc "Creates a new entry from a source path and optional keyword opts."
  def new(path, opts \\ []) do
    %__MODULE__{
      path: path,
      worktree_enabled: Keyword.get(opts, :worktree_enabled, false),
      worktree_path: Keyword.get(opts, :worktree_path)
    }
  end

  @doc "Returns the effective working directory: worktree path when active, otherwise source path."
  def effective_path(%__MODULE__{worktree_path: wp}) when is_binary(wp), do: wp
  def effective_path(%__MODULE__{path: p}), do: p

  @doc "Serialises to a plain map for JSON encoding."
  def to_map(%__MODULE__{} = e) do
    base = %{"path" => e.path, "worktree_enabled" => e.worktree_enabled}
    if e.worktree_path, do: Map.put(base, "worktree_path", e.worktree_path), else: base
  end

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
      worktree_path: Map.get(m, "worktree_path")
    }
  end
end

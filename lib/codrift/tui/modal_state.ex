defmodule Codrift.TUI.ModalState do
  @moduledoc false

  defstruct type: :none,
            input: nil,
            context: nil,
            actions: [],
            palette: %{cursor: 0, filter: ""},
            theme_picker: %{cursor: 0, before: nil},
            dir_picker: %{suggestions: [], cursor: 0},
            source_picker: %{cursor: 0},
            agent_picker: %{cursor: 0},
            service_setup: %{cursor: 0},
            worktree_git: false,
            worktree_enabled: false
end

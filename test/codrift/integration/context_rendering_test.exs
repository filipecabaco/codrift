defmodule Codrift.Integration.ContextRenderingTest do
  @moduledoc """
  `to_initiative_context/1` — the one part of each tracker adapter that is pure,
  and the part a person actually reads: it becomes the body of `initiative.md`,
  which is what every agent on that initiative is briefed from.

  The failure worth guarding is an unfilled field rendering as nothing. An issue
  with no description must not brief an agent with a blank Description section,
  and `nil` must never reach the file as the word "nil" or an empty label list
  as "[]".

  The network halves of these adapters are not reachable from here — `Codrift.
  Integration.HTTP` talks to real hosts with no injection point — so this covers
  the rendering contract, not the fetching.
  """
  use ExUnit.Case, async: true

  alias Codrift.Integration
  alias Codrift.Integration.Item

  defp full_item do
    %Item{
      id: "42",
      title: "Fix the flaky login test",
      description: "It fails about one run in five.",
      url: "https://example.test/issues/42",
      labels: ["bug", "flaky"],
      status: "in progress",
      assignee: "filipe",
      linked_prs: [],
      metadata: %{}
    }
  end

  defp bare_item do
    %Item{
      id: "43",
      title: "Untitled work",
      description: nil,
      url: "https://example.test/issues/43",
      labels: [],
      status: nil,
      assignee: nil,
      linked_prs: [],
      metadata: %{}
    }
  end

  defp adapters do
    for service <- Integration.valid_services() do
      {:ok, adapter} = Integration.adapter_for(service, skip_credentials: true)
      {service, adapter}
    end
  end

  # Adapters do not all render the same brief: some describe an issue (assignee,
  # labels), some a project (progress, member issues). Split on what each one
  # actually produces rather than on its name — `github_projects` renders issue
  # briefs despite the name, and a name-based guess quietly tested the wrong
  # contract for it.
  defp issue_adapters,
    do:
      Enum.filter(adapters(), fn {_, a} ->
        a.to_initiative_context(full_item()) =~ "**Assignee:**"
      end)

  defp project_adapters,
    do:
      Enum.filter(adapters(), fn {_, a} -> a.to_initiative_context(full_item()) =~ "## Issues" end)

  test "every adapter renders the title, URL and description of a filled item" do
    for {service, adapter} <- adapters() do
      context = adapter.to_initiative_context(full_item())

      assert context =~ "# Fix the flaky login test", "#{service} dropped the title"
      assert context =~ "https://example.test/issues/42", "#{service} dropped the URL"
      assert context =~ "It fails about one run in five.", "#{service} dropped the description"
    end
  end

  test "the two shapes between them account for every adapter" do
    assert Enum.count(issue_adapters()) + Enum.count(project_adapters()) ==
             Enum.count(adapters()),
           "an adapter renders neither an issue brief nor a project brief"
  end

  test "issue adapters render the assignee and the labels" do
    for {service, adapter} <- issue_adapters() do
      context = adapter.to_initiative_context(full_item())

      assert context =~ "filipe", "#{service} dropped the assignee"
      assert context =~ "bug, flaky", "#{service} should join labels with a comma"
      refute context =~ "[\"bug\"", "#{service} leaked a raw list into the brief"
    end
  end

  test "an empty item never briefs an agent with nil or a raw empty list" do
    for {service, adapter} <- adapters() do
      context = adapter.to_initiative_context(bare_item())

      refute context =~ "nil", "#{service} rendered a nil into the brief"
      refute context =~ "[]", "#{service} rendered an empty list into the brief"

      assert context =~ "No description provided",
             "#{service} left the description section empty"
    end
  end

  test "an empty issue says unassigned and none rather than leaving the field bare" do
    for {service, adapter} <- issue_adapters() do
      context = adapter.to_initiative_context(bare_item())

      assert context =~ "unassigned", "#{service} left the assignee blank"
      assert context =~ "none", "#{service} left the labels blank"
    end
  end

  test "a project with no linked issues says so instead of showing an empty list" do
    for {service, adapter} <- project_adapters() do
      context = adapter.to_initiative_context(bare_item())
      assert context =~ "No issues linked", "#{service} left the issue list bare"
    end
  end

  test "the brief always opens with the title as a heading" do
    for {service, adapter} <- adapters() do
      [first | _] = adapter.to_initiative_context(full_item()) |> String.split("\n")
      assert first == "# Fix the flaky login test", "#{service} did not lead with the title"
    end
  end

  test "the brief names the service it came from, so its origin survives the copy" do
    for {service, adapter} <- adapters() do
      context = adapter.to_initiative_context(full_item())
      assert context =~ "**Source:**", "#{service} omitted the source line"
    end
  end
end

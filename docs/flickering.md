# Sidequest: Reduce TUI Flickering

**Priority: low — correctness and features first.**

## Root cause

The render loop triggers resizes on panes (PTY, content pane, sidebar) to keep them correctly sized after layout changes. Each resize round-trips through the terminal: the BEAM emits escape sequences, the terminal redraws, and if multiple resizes fire in quick succession the user sees a flash between intermediate states.

## Five identified sources (cheapest to most invasive)

### 1. `AgentProcess.resize/3` has no deduplication

`process.ex:170-176` — `handle_cast({:resize, cols, rows}, ...)` calls `:exec.winsz/3` unconditionally. No guard for "same size as last time".

**Fix:** Add `last_size: nil` to `AgentProcess` state. Only call `:exec.winsz` when `{cols, rows} != state.last_size`.

```elixir
def handle_cast({:resize, cols, rows}, %{mode: :pty, exec_ospid: ospid} = state)
    when not is_nil(ospid) and {cols, rows} != state.last_size do
  :exec.winsz(ospid, rows, cols)
  {:noreply, %{state | last_size: {cols, rows}}}
rescue
  _ -> {:noreply, state}
end

def handle_cast({:resize, _cols, _rows}, state), do: {:noreply, state}
```

### 2. `resize_all_ptys/2` resizes every agent on every terminal resize event

`tui.ex:1774-1778` — signals every agent including hidden ones. SIGWINCH causes the child process to redraw, perturbing scroll regions and cursor position.

**Fix:** Resize only the selected agent immediately. Non-selected agents already pick up correct dimensions via `subscribe_to_agent/2` when they become visible.

```elixir
# in handle_info({:apply_resize, w, h}, state)
if state.selected_agent_id do
  case AgentSupervisor.find_agent(state.selected_agent_id) do
    {:ok, pid} -> AgentProcess.resize(pid, pane_w, pane_h)
    _ -> :ok
  end
end
```

### 3. `handle_info({:apply_resize, ...})` does not guard against no-op resizes

`tui.ex:595-620` — always calls `resize_all_ptys/2` and rebuilds all VT100 screens, even when `{pane_w, pane_h}` equals `state.pane_size`.

**Fix:** Early-return when computed pane size matches stored size.

```elixir
def handle_info({:apply_resize, w, h}, state) do
  {pane_w, pane_h} = calc_pane_size(w, h, state.sidebar_collapsed)

  if {pane_w, pane_h} == state.pane_size do
    {:noreply, %{state | resize_ref: nil}}
  else
    # ... existing resize logic ...
  end
end
```

### 4. Each agent subscription fires 3–4 resize calls in 600 ms

`tui.ex:1275-1278` — sends `w-1`, then schedules `{:restore_agent_size}` at +150 ms, then `{:input_nudge}` at +60 ms, then `{:nudge_agent}` at +600 ms. Total: up to 4 SIGWINCH + 1 `\r` per subscription. Each SIGWINCH causes Claude Code / Ink to do a `\e[2J` full repaint.

**Fix (conservative):** Only schedule the 600 ms nudge if there is no existing output.

```elixir
if Enum.empty?(replay) do
  Process.send_after(self(), {:nudge_agent, agent_id, w, h}, 600)
end
```

**Fix (aggressive):** Track `nudge_ref` and `restore_ref` alongside `resize_ref`. Cancel stale timers before scheduling new ones.

### 5. Stale nudge/restore timers accumulate during rapid navigation

`tui.ex:1246` — `maybe_subscribe_agent/2` calls `Process.send_after` with no cancellation of any previous pending nudge. `{:restore_agent_size}` timers can pile up across agent switches.

**Fix:** Add `nudge_ref: nil` and `restore_ref: nil` to the `defstruct`; cancel-before-schedule in the same pattern as `resize_ref`.

```elixir
if state.nudge_ref, do: Process.cancel_timer(state.nudge_ref)
ref = Process.send_after(self(), {:nudge_agent, agent_id, w, h}, 80)
%{state | nudge_ref: ref}
```

## Suggested implementation order

1. Fix 1 — ~5 lines, zero risk, deduplicates at the root
2. Fix 3 — ~5 lines, eliminates spurious full repaints
3. Fix 5 — ~10 lines, prevents timer pile-up during navigation
4. Fix 4 — ~5 lines, halves the repaint count on subscription
5. Fix 2 — bigger change, highest payoff when many agents are running

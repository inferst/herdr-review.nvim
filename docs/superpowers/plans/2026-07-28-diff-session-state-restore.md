# Diff Session State Restoration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve the review diff layout and cursor when the same review is refreshed, reopened from the originating tab, or closed and reopened, without changing comment storage.

**Architecture:** `review-diff.View` owns transient display-state snapshots and restores them during `replace()` only for a matching `review_id`. `herdr-review.init` captures state before asynchronous Git refreshes, while `herdr-review.session` only bridges comments and holds a matching pending snapshot across a closed review tab.

**Tech Stack:** Lua, Neovim 0.10+, Plenary/Busted, StyLua, Luacheck, the existing `review-diff` viewer and Git adapter.

## Global Constraints

- UI layout state is in-memory only; do not change the JSON session schema or comment storage.
- Restore state only when the saved and current `review_id` values match.
- Restore stale files/lines on a best-effort basis without raising errors.
- Preserve the repository's two-space Lua style, local variables, module tables, and existing LuaDoc annotations.
- Keep async Git generation checks intact so stale resolve callbacks cannot replace the active view.
- Use `make check PLENARY_PATH=deps/plenary.nvim` for the final verification.

---

## File Map

- Modify `lua/review-diff/init.lua`: add viewer-owned state capture/restore, track the last active diff side, and make `View:replace()` accept an optional snapshot.
- Modify `lua/herdr-review/init.lua`: capture state before `R` and repeated `:ReviewDiff` async jobs, then pass it to `View:replace()`.
- Modify `lua/herdr-review/session.lua`: remove layout-specific snapshot parsing and keep only matching pending state across view close/open lifecycle events.
- Modify `tests/review_diff_view_spec.lua`: cover viewer state APIs, replace behavior, focus outside the review tab, side-specific paths, and review identity changes.
- Modify `tests/session_spec.lua`: cover matching close/reopen restoration and disposal of mismatched pending state.
- Do not modify `lua/herdr-review/storage.lua` or the storage tests.

## Interfaces

The viewer API produced by the implementation is:

```lua
---@return table
function View:capture_state()
end

---@param snapshot table|nil
function View:restore_state(snapshot)
end

---@param input table
---@param opts table|nil
function View:replace(input, opts)
end
```

`opts.state` is the optional snapshot passed by the plugin before an async
refresh. When omitted, `replace()` captures its own current state. The
snapshot shape is:

```lua
{
  review_id = "stable-review-id",
  collapsed_files = { ["file-id"] = true|false },
  expanded_folds = { ["file-id:first:last"] = true },
  cursor = { file = "relative/path.lua", side = "old"|"new", line = 42 },
}
```

### Task 1: Add and implement viewer-owned state restoration

**Files:**
- Modify: `tests/review_diff_view_spec.lua`
- Modify: `lua/review-diff/init.lua`

**Interfaces:**
- Consumes: existing `View.files`, `View.display_rows`, `View.state`, `View.win_sides`, `View:render()`, and `View:set_cursor_row()`.
- Produces: `View:capture_state()`, `View:restore_state(snapshot)`, and `View:replace(input, opts)` behavior used by Tasks 2 and 3.

- [ ] **Step 1: Add failing tests for the state contract.**

  Extend `tests/review_diff_view_spec.lua` with fixtures that include two files
  and enough unchanged lines to produce a context fold. Add tests asserting:

  ```lua
  view.state.collapsed_files["lua/a.lua"] = false
  view.state.collapsed_files["lua/b.lua"] = true
  view.state.expanded_folds["lua/a.lua:1:4"] = true
  vim.api.nvim_set_current_win(view.old_win)

  local snapshot = view:capture_state()

  assert.are.equal(view:get_review_id(), snapshot.review_id)
  assert.is_false(snapshot.collapsed_files["lua/a.lua"])
  assert.is_true(snapshot.collapsed_files["lua/b.lua"])
  assert.is_true(snapshot.expanded_folds["lua/a.lua:1:4"])
  assert.are.equal("old", snapshot.cursor.side)
  ```

  Add a focus-away case: move the cursor in `view.new_win`, switch to
  `view.origin.tabpage`/`view.origin.win`, call `capture_state()`, and assert
  that the snapshot still contains the new-side file and line. Add a renamed
  file case with `old_path = "old.lua"` and `new_path = "new.lua"`; capture on
  `old_win` and assert `snapshot.cursor.file == "old.lua"`.

  Add replace tests that set the saved layout, call:

  ```lua
  view:replace(same_review_input, { state = view:capture_state() })
  ```

  and assert the explicit `false`, expanded fold key, and cursor are present
  after replacement. Register a `ready` callback that mutates layout state and
  assert the final state is the snapshot, proving restoration runs after ready
  callbacks. Add a different-`review_id` replacement and assert the default
  `collapse_on_open` layout and initial cursor are used instead.

- [ ] **Step 2: Run the focused viewer tests and verify they fail for the missing contract.**

  Run:

  ```sh
  PLENARY_PATH=deps/plenary.nvim nvim --headless -u tests/minimal_init.lua -i NONE -n \
    -c 'PlenaryBustedFile tests/review_diff_view_spec.lua { minimal_init = "tests/minimal_init.lua" }'
  ```

  Expected: failures for the missing `capture_state()`/`restore_state()` API
  and for `replace()` resetting the saved layout.

- [ ] **Step 3: Track the last active diff side in the viewer.**

  Initialize a `last_side` field to the new side when constructing a view.
  Update it whenever a valid review window becomes active, including the
  `CursorMoved` autocmd, `open_location()`, and cursor movement helpers. Do not
  infer the side from the current Neovim window when that window is outside the
  review tab.

- [ ] **Step 4: Implement `capture_state()` using view-owned windows.**

  Add a helper that resolves a cursor location from a specific view window,
  rather than only from `nvim_get_current_win()`. `capture_state()` should read
  the last active side's valid window, copy `collapsed_files` and
  `expanded_folds` with `vim.deepcopy`, and record the side-specific path:

  ```lua
  local path = side == "old" and row.file.old_path or row.file.new_path
  ```

  For a line row, store its side-specific source line. For a file header or
  fold row, store the best available file/side anchor so restore can place the
  cursor on that header or fold indicator. Return `nil` only when the view has
  no review identity; a view with no usable cursor still returns its layout
  maps with `cursor = nil`.

- [ ] **Step 5: Implement `restore_state(snapshot)` defensively.**

  Return immediately when `snapshot` is nil or its `review_id` does not match
  `self:get_review_id()`. Copy only collapsed-file entries whose file IDs exist
  in the new model and copy the expanded-fold table before rendering. When a
  cursor points to a source line in a collapsed file, uncollapse that file so
  the cursor can be made visible. Render once, find the matching file row by
  side-specific path, and set both aligned windows to the matching row while
  preserving the saved side in `last_side`.

  Match a folded cursor by checking the fold's source rows for the saved side
  line; do not compare a source-row index directly to a source line number.
  If the line is stale, fall back to the file header or leave the initial
  cursor in place. Never call `error()` or notify for a stale UI cursor.

- [ ] **Step 6: Update `View:replace(input, opts)` to use the snapshot.**

  At the beginning of `replace()`, select `opts.state` when supplied, otherwise
  call `self:capture_state()`. Build the new model, then initialize
  `collapsed_files` with an explicit nil check so `false` survives:

  ```lua
  local saved = snapshot and snapshot.collapsed_files[file.id]
  self.state.collapsed_files[file.id] = saved ~= nil and saved or self.options.collapse_on_open
  ```

  Preserve `expanded_folds` only for a matching `review_id`; otherwise use an
  empty table. Place the initial cursor and emit `ready` as today, then call
  `restore_state(snapshot)` after callbacks when the IDs match. Keep the
  existing render and annotation behavior intact.

- [ ] **Step 7: Run the focused viewer tests and commit the self-contained viewer change.**

  Run the focused command from Step 2 and then:

  ```sh
  git diff --check
  git add lua/review-diff/init.lua tests/review_diff_view_spec.lua
  git commit -m "fix: preserve review diff view state"
  ```

  Expected: the viewer state tests pass, including same-review restore,
  different-review reset, focus-away capture, explicit `false`, folds, and
  old-side renamed paths.

### Task 2: Move close/reopen state bridging into the session lifecycle

**Files:**
- Modify: `lua/herdr-review/session.lua`
- Modify: `tests/session_spec.lua`

**Interfaces:**
- Consumes: `view:capture_state()` and `view:restore_state(snapshot)` from Task 1.
- Produces: matching pending-state behavior for `session.on_view_closed(view)` and `session.on_view_opened(view)`.

- [ ] **Step 1: Add failing close/reopen tests.**

  Add a session test that attaches the session lifecycle callbacks to a view,
  changes collapsed files, expands a fold, and moves the cursor to the old
  side. Close the view, open a new view with the same `review_id`, call
  `session.on_view_opened(reopened)`, and assert all saved view state is
  restored after comments are loaded.

  Add a mismatch test: close a configured view, open a different `review_id`,
  call `session.on_view_opened(other_view)`, then open the original review and
  assert the old snapshot was discarded rather than applied later.

- [ ] **Step 2: Run the focused session tests and verify they expose the old implementation.**

  Run:

  ```sh
  PLENARY_PATH=deps/plenary.nvim nvim --headless -u tests/minimal_init.lua -i NONE -n \
    -c 'PlenaryBustedFile tests/session_spec.lua { minimal_init = "tests/minimal_init.lua" }'
  ```

  Expected: the new close/reopen assertions fail because the old session module
  either has no matching pending-state contract or does not delegate all
  layout fields.

- [ ] **Step 3: Replace session-local layout parsing with a pending snapshot.**

  Remove `previous_view_state`, `file_for_path()`, and the layout-specific
  `capture_view_state()`/`restore_view_state()` implementation from
  `lua/herdr-review/session.lua`. Add one `pending_view_state` local.

  In `on_view_closed(view)`, capture the view state before resetting active
  comment state and retain that snapshot as pending. In `on_view_opened(view)`,
  load comments first; then consume the pending snapshot exactly once. Apply it
  only when `snapshot.review_id == view:get_review_id()`, otherwise clear it.
  Keep `reset()` clearing active comment state and pending data when called
  explicitly so tests and future lifecycle resets cannot leak state.

- [ ] **Step 4: Run the focused session tests and commit the lifecycle change.**

  Run the focused command from Step 2, then:

  ```sh
  git diff --check
  git add lua/herdr-review/session.lua tests/session_spec.lua
  git commit -m "fix: restore review state across reopen"
  ```

  Expected: matching close/reopen restores the view and mismatched reviews
  consume and discard the pending snapshot.

### Task 3: Pass early snapshots through plugin async refreshes

**Files:**
- Modify: `lua/herdr-review/init.lua`

**Interfaces:**
- Consumes: `view:capture_state()` and `view:replace(input, { state = snapshot })` from Task 1.
- Produces: state-preserving `R` and repeated `:ReviewDiff` workflows.

- [ ] **Step 1: Capture refresh state before starting the Git job.**

  In the `refresh_requested` callback, replace the session-local capture call
  with:

  ```lua
  local saved_state = current_view:capture_state()
  ```

  Pass that snapshot to the guarded resolve callback:

  ```lua
  current_view:replace(input, { state = saved_state })
  ```

  Preserve the existing `generation` checks, cancellation, and error
  notifications.

- [ ] **Step 2: Capture repeated-review state before changing origin or focus.**

  In `start_review()`, when `viewer.current()` returns an existing view, call
  `view:capture_state()` before `set_origin()`, `focus()`, or launching the new
  Git resolve. Pass the captured state to `view:replace()` in the `on_ready`
  callback. Keep the loading-view path unchanged except that its first real
  replacement must not restore the temporary `review_id = "loading"` state.

- [ ] **Step 3: Run the full automated suite and inspect the integration diff.**

  Run:

  ```sh
  make check PLENARY_PATH=deps/plenary.nvim
  git diff HEAD~2 -- lua/herdr-review/init.lua lua/herdr-review/session.lua lua/review-diff/init.lua
  ```

  Expected: format, lint, and all tests pass; both async replacement paths pass
  an early snapshot, and no storage or generation-check code changes appear in
  the diff.

- [ ] **Step 4: Commit the plugin integration.**

  ```sh
  git add lua/herdr-review/init.lua
  git commit -m "fix: preserve state during review refresh"
  ```

### Task 4: Manual regression verification and final cleanup

**Files:**
- Modify: none unless verification reveals a focused defect in the files above.

**Interfaces:**
- Consumes: the completed viewer and plugin lifecycle behavior from Tasks 1-3.
- Produces: verified user workflow and a clean working tree.

- [ ] **Step 1: Run the complete check from a clean dependency path.**

  Run:

  ```sh
  make check PLENARY_PATH=deps/plenary.nvim
  git status --short
  ```

  Expected: format-check, luacheck, and tests all pass; only the intended
  implementation commits are present and no unrelated files are modified.

- [ ] **Step 2: Manually verify repeated `:ReviewDiff`.**

  In a repository with a worktree diff:

  1. Run `:ReviewDiff`.
  2. Move to a non-initial hunk, collapse one file, expand a context fold, and
     place the cursor on the old side.
  3. Move to a new-side changed line and press `<CR>`.
  4. From the opened originating file, run `:ReviewDiff` with the same range.
  5. Confirm the review tab returns to the same file, fold/collapse layout,
     cursor line, and diff side.

- [ ] **Step 3: Manually verify refresh and review identity boundaries.**

  Press `R` after changing layout and confirm the same state is restored. Close
  the review tab and reopen the same review to confirm restoration. Then open a
  different review range and confirm it starts with its configured defaults,
  without the previous review's cursor or fold state.

- [ ] **Step 4: Record final verification and leave the tree clean.**

  Re-run `git diff --check` and `git status --short`. Report the automated
  command result and any manual workflow limitations without claiming success
  for an unverified path.

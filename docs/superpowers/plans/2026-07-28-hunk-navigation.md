# Hunk Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `[c` and `]c` navigate by true diff hunks, including hunks in collapsed files.

**Architecture:** `review-diff.model` will expose `file.hunks` as stable source-row ranges derived from the diff indices. `review-diff`'s `View` will use those model hunks for UI navigation while keeping file expansion, fold expansion, cursor placement, and wrap-around behaviour in the view layer.

**Tech Stack:** Lua, Neovim API, Plenary tests, Make, StyLua, Luacheck.

## Global Constraints

- Runtime source stays under `lua/`; tests stay under `tests/`.
- Lua uses two-space indentation, local variables by default, and module tables returned from each file.
- Public module functions stay `snake_case`.
- Preserve existing LuaDoc annotations when changing interfaces.
- Do not add dependencies.
- Use `make test PLENARY_PATH=deps/plenary.nvim` for test verification.
- Use `make check PLENARY_PATH=deps/plenary.nvim` before final handoff.

---

## File Structure

- `lua/review-diff/model.lua`
  - Owns diff structure.
  - Adds `file.hunks`, where each hunk is a stable range in `file.rows`.
  - Does not call Neovim window or buffer APIs beyond existing diff/string helpers.
- `lua/review-diff/init.lua`
  - Owns review-tab UI behaviour.
  - Replaces rendered changed-line scanning with model-backed hunk target navigation.
  - Opens collapsed files and restores the active old/new side when jumping.
- `tests/review_diff_model_spec.lua`
  - Verifies hunk metadata shape and range semantics.
- `tests/review_diff_view_spec.lua`
  - Verifies user-visible hunk navigation behaviour.
- `README.md`
  - Documents `]c` / `[c` as hunk navigation.

---

### Task 1: Add model-level hunk metadata

**Files:**
- Modify: `lua/review-diff/model.lua:37-145`
- Test: `tests/review_diff_model_spec.lua`

**Interfaces:**
- Consumes: existing `M.build_file(file, opts)` and existing `file.rows`.
- Produces: every `M.build_file()` result includes `hunks`.
- Produces hunk shape:

```lua
{
  id = 1,                 -- integer, 1-based within the file
  first_row = 2,          -- integer index into file.rows
  last_row = 3,           -- integer index into file.rows
  old_start = 2,          -- integer|nil source line
  old_end = 3,            -- integer|nil source line
  new_start = 2,          -- integer|nil source line
  new_end = 3,            -- integer|nil source line
}
```

- For add-only hunks: `old_start = nil`, `old_end = nil`.
- For delete-only hunks: `new_start = nil`, `new_end = nil`.
- Binary and too-large files produce `hunks = {}`.

- [ ] **Step 1: Write failing model tests**

Add these tests in `tests/review_diff_model_spec.lua`, after the existing `"maps changed source lines to one aligned row"` test:

```lua
  it("records one hunk for a multi-line contiguous change", function()
    local file = model.build_file({
      old_path = "lua/example.lua",
      new_path = "lua/example.lua",
      old_text = "one\nold a\nold b\nfour",
      new_text = "one\nnew a\nnew b\nfour",
      status = "modified",
    })

    assert.are.same({
      {
        id = 1,
        first_row = 2,
        last_row = 3,
        old_start = 2,
        old_end = 3,
        new_start = 2,
        new_end = 3,
      },
    }, file.hunks)
  end)

  it("records separate hunks for separate changed ranges", function()
    local file = model.build_file({
      old_path = "lua/example.lua",
      new_path = "lua/example.lua",
      old_text = "one\ntwo\nthree\nfour",
      new_text = "one\nthree\ninserted\nfour",
      status = "modified",
    })

    assert.are.same({
      {
        id = 1,
        first_row = 2,
        last_row = 2,
        old_start = 2,
        old_end = 2,
        new_start = nil,
        new_end = nil,
      },
      {
        id = 2,
        first_row = 4,
        last_row = 4,
        old_start = nil,
        old_end = nil,
        new_start = 3,
        new_end = 3,
      },
    }, file.hunks)
  end)

  it("keeps binary and too-large files out of hunk navigation", function()
    local binary = model.build_file({
      old_path = "bin/example",
      new_path = "bin/example",
      binary = true,
      status = "binary",
    })
    local too_large = model.build_file({
      old_path = "lua/large.lua",
      new_path = "lua/large.lua",
      too_large = true,
      status = "modified",
    })

    assert.are.same({}, binary.hunks)
    assert.are.same({}, too_large.hunks)
  end)
```

- [ ] **Step 2: Run the model spec and verify it fails**

Run:

```bash
make test PLENARY_PATH=deps/plenary.nvim
```

Expected: `review_diff_model_spec.lua` fails because `file.hunks` is `nil`.

- [ ] **Step 3: Implement hunk metadata in the model**

In `lua/review-diff/model.lua`, add helpers near `hunk_line_start()`:

```lua
local function source_range(start, count)
  if count == 0 then
    return nil, nil
  end
  return start, start + count - 1
end

local function hunk_metadata(id, first_row, last_row, hunk)
  local old_count = hunk[2]
  local new_count = hunk[4]
  local old_start_line = hunk_line_start(hunk[1], old_count)
  local new_start_line = hunk_line_start(hunk[3], new_count)
  local old_start, old_end = source_range(old_start_line, old_count)
  local new_start, new_end = source_range(new_start_line, new_count)

  return {
    id = id,
    first_row = first_row,
    last_row = last_row,
    old_start = old_start,
    old_end = old_end,
    new_start = new_start,
    new_end = new_end,
  }
end
```

In `M.build_file()`, initialize hunks before the binary/too-large early return:

```lua
  result.rows = {}
  result.hunks = {}

  if result.binary or result.too_large then
    return result
  end
```

In the `for _, hunk in ipairs(hunks) do` loop, record the row range created by `append_change_rows()`:

```lua
    local first_row = #result.rows + 1
    old_cursor, new_cursor = append_change_rows(result.rows, old_lines, new_lines, hunk)
    local last_row = #result.rows

    table.insert(result.hunks, hunk_metadata(#result.hunks + 1, first_row, last_row, hunk))
```

Remove the old direct assignment:

```lua
    old_cursor, new_cursor = append_change_rows(result.rows, old_lines, new_lines, hunk)
```

- [ ] **Step 4: Run the model spec and verify it passes**

Run:

```bash
make test PLENARY_PATH=deps/plenary.nvim
```

Expected: all tests pass.

- [ ] **Step 5: Commit model hunk metadata**

Run:

```bash
git add lua/review-diff/model.lua tests/review_diff_model_spec.lua
git commit -m "feat: add review diff hunk metadata"
```

---

### Task 2: Navigate by hunk instead of changed line

**Files:**
- Modify: `lua/review-diff/init.lua:700-780`
- Test: `tests/review_diff_view_spec.lua`

**Interfaces:**
- Consumes: `file.hunks` from Task 1.
- Produces: `View:move_hunk(direction)` moves one hunk at a time.
- Produces helper contract: a hunk target is `{ file = file, hunk = hunk, source_index = hunk.first_row }`.

- [ ] **Step 1: Write failing view tests for hunk-level movement**

Add these tests in `tests/review_diff_view_spec.lua`, before `"invalidates itself when the review tab is closed externally"`:

```lua
  it("moves by hunk instead of changed line", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-hunk-move",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\nold a\nold b\nfour\nfive\nsix",
          new_text = "one\nnew a\nnew b\nfour\nchanged five\nsix",
          status = "modified",
        },
      },
    }, { syntax = false })

    vim.api.nvim_set_current_win(view.new_win)
    assert.are.same({ file = "lua/example.lua", side = "new", line = 2 }, view:get_cursor_location())

    view:move_hunk(1)

    assert.are.same({ file = "lua/example.lua", side = "new", line = 5 }, view:get_cursor_location())
  end)

  it("wraps hunk navigation at the first and last hunk", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-hunk-wrap",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\nold a\nold b\nfour\nfive\nsix",
          new_text = "one\nnew a\nnew b\nfour\nchanged five\nsix",
          status = "modified",
        },
      },
    }, { syntax = false })

    vim.api.nvim_set_current_win(view.new_win)
    assert.are.same({ file = "lua/example.lua", side = "new", line = 2 }, view:get_cursor_location())

    view:move_hunk(-1)
    assert.are.same({ file = "lua/example.lua", side = "new", line = 5 }, view:get_cursor_location())

    view:move_hunk(1)
    assert.are.same({ file = "lua/example.lua", side = "new", line = 2 }, view:get_cursor_location())
  end)
```

- [ ] **Step 2: Run the view spec and verify it fails**

Run:

```bash
make test PLENARY_PATH=deps/plenary.nvim
```

Expected: `"moves by hunk instead of changed line"` fails because current `View:move_hunk(1)` lands on line `3`.

- [ ] **Step 3: Add hunk target helpers**

In `lua/review-diff/init.lua`, replace the current `View:move_hunk()` implementation and add helpers near `move_to_rows()`:

```lua
local function source_index_for_display_row(row)
  if not row or row.display_kind ~= "line" or not row.file then
    return nil
  end
  for index, source_row in ipairs(row.file.rows or {}) do
    if source_row == row.source_row then
      return index
    end
  end
  return nil
end

local function collect_hunk_targets(view)
  local targets = {}
  for _, file in ipairs(view.files) do
    for _, hunk in ipairs(file.hunks or {}) do
      table.insert(targets, {
        file = file,
        hunk = hunk,
        source_index = hunk.first_row,
      })
    end
  end
  return targets
end

local function hunk_contains_source_index(hunk, source_index)
  return source_index and source_index >= hunk.first_row and source_index <= hunk.last_row
end

local function current_hunk_target_index(view, targets)
  local cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
  local row = view.display_rows[cursor[1]]
  local source_index = source_index_for_display_row(row)
  if not source_index then
    return nil
  end
  for index, target in ipairs(targets) do
    if target.file == row.file and hunk_contains_source_index(target.hunk, source_index) then
      return index
    end
  end
  return nil
end

local function next_hunk_target_index(view, targets, direction)
  local current_index = current_hunk_target_index(view, targets)
  if current_index then
    if direction > 0 then
      return current_index == #targets and 1 or current_index + 1
    end
    return current_index == 1 and #targets or current_index - 1
  end
  return direction > 0 and 1 or #targets
end
```

Add this method near `View:expand_location()`:

```lua
function View:expand_source_row(file, source_index)
  if not file then
    return false
  end
  self.state.collapsed_files[file.id] = false
  if not source_index then
    return true
  end
  for _, row in ipairs(model.visible_rows(file, self.state.context_lines)) do
    if row.kind == "fold" and source_index >= row.first_row and source_index <= row.last_row then
      local key = string.format("%s:%d:%d", file.id, row.first_row, row.last_row)
      self.state.expanded_folds[key] = true
      break
    end
  end
  return true
end
```

Update `View:expand_location()` to reuse the new helper:

```lua
function View:expand_location(location)
  local file = file_for_location(self.files, location)
  if not file then
    return nil
  end
  local side_line = location.side .. "_line"
  local source_index
  for index, row in ipairs(file.rows) do
    if row[side_line] == location.line then
      source_index = index
      break
    end
  end
  self:expand_source_row(file, source_index)
  return file
end
```

Add a source-row display lookup:

```lua
local function display_row_for_source_index(view, file, source_index)
  for index, row in ipairs(view.display_rows) do
    if row.display_kind == "line" and row.file == file and row.source_row == file.rows[source_index] then
      return index
    end
  end
  return nil
end
```

Replace `View:move_hunk()`:

```lua
function View:move_hunk(direction)
  local targets = collect_hunk_targets(self)
  if #targets == 0 then
    return
  end

  local target = targets[next_hunk_target_index(self, targets, direction)]
  if not target then
    return
  end

  self:expand_source_row(target.file, target.source_index)
  self:render()

  local row_index = display_row_for_source_index(self, target.file, target.source_index)
  if row_index then
    self:set_cursor_row(row_index)
  end
end
```

- [ ] **Step 4: Run the view spec and verify it passes**

Run:

```bash
make test PLENARY_PATH=deps/plenary.nvim
```

Expected: all tests pass.

- [ ] **Step 5: Commit hunk movement**

Run:

```bash
git add lua/review-diff/init.lua tests/review_diff_view_spec.lua
git commit -m "feat: navigate review diff by hunk"
```

---

### Task 3: Open collapsed files during hunk navigation

**Files:**
- Modify: `lua/review-diff/init.lua:700-780`
- Test: `tests/review_diff_view_spec.lua`

**Interfaces:**
- Consumes: `View:expand_source_row(file, source_index)` from Task 2.
- Produces: `View:move_hunk(direction)` can choose targets that are hidden behind a collapsed file header.
- Produces: active old/new side remains the current focused review side after navigation.

- [ ] **Step 1: Write failing tests for collapsed files and active side preservation**

Add these tests in `tests/review_diff_view_spec.lua`, after the hunk movement tests from Task 2:

```lua
  it("opens the target file when hunk navigation lands in a collapsed file", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-hunk-collapsed-file",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/a.lua",
          old_path = "lua/a.lua",
          new_path = "lua/a.lua",
          old_text = "one\ntwo",
          new_text = "one\nchanged two",
          status = "modified",
        },
        {
          id = "lua/b.lua",
          old_path = "lua/b.lua",
          new_path = "lua/b.lua",
          old_text = "alpha\nbeta",
          new_text = "alpha\nchanged beta",
          status = "modified",
        },
      },
    }, { collapse_on_open = true, syntax = false })

    vim.api.nvim_set_current_win(view.new_win)
    vim.api.nvim_win_set_cursor(view.new_win, { 2, 0 })

    assert.is_true(view.state.collapsed_files["lua/a.lua"])
    assert.is_true(view.state.collapsed_files["lua/b.lua"])

    view:move_hunk(1)

    assert.is_true(view.state.collapsed_files["lua/a.lua"])
    assert.is_false(view.state.collapsed_files["lua/b.lua"])
    assert.are.same({ file = "lua/b.lua", side = "new", line = 2 }, view:get_cursor_location())
  end)

  it("preserves the active diff side when moving between hunks", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-hunk-side",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\nold a\nold b\nfour\nfive\nsix",
          new_text = "one\nnew a\nnew b\nfour\nchanged five\nsix",
          status = "modified",
        },
      },
    }, { syntax = false })

    vim.api.nvim_set_current_win(view.old_win)

    view:move_hunk(1)

    assert.are.equal(view.old_win, vim.api.nvim_get_current_win())
    assert.are.same({ file = "lua/example.lua", side = "old", line = 5 }, view:get_cursor_location())
  end)
```

- [ ] **Step 2: Run the view spec and verify it fails**

Run:

```bash
make test PLENARY_PATH=deps/plenary.nvim
```

Expected: the collapsed-file test fails because Task 2's fallback selection chooses the first target by list order instead of treating the current collapsed `lua/b.lua` header as the next target anchor.

- [ ] **Step 3: Add target anchors for hidden hunks**

In `lua/review-diff/init.lua`, add an anchor helper near `display_row_for_source_index()`:

```lua
local function file_header_row(view, file)
  for index, row in ipairs(view.display_rows) do
    if row.display_kind == "file_header" and row.file == file then
      return index
    end
  end
  return nil
end

local function target_anchor_row(view, target)
  local exact = display_row_for_source_index(view, target.file, target.source_index)
  if exact then
    return exact
  end

  for index, row in ipairs(view.display_rows) do
    if
      row.display_kind == "fold"
      and row.file == target.file
      and target.source_index >= row.fold.first_row
      and target.source_index <= row.fold.last_row
    then
      return index
    end
  end

  return file_header_row(view, target.file)
end
```

Replace `next_hunk_target_index()` with anchored fallback selection:

```lua
local function cursor_on_collapsed_file_header(view, cursor_row, target)
  local row = view.display_rows[cursor_row]
  return row
    and row.display_kind == "file_header"
    and row.file == target.file
    and row.collapsed == true
end

local function next_hunk_target_index(view, targets, direction)
  local current_index = current_hunk_target_index(view, targets)
  if current_index then
    if direction > 0 then
      return current_index == #targets and 1 or current_index + 1
    end
    return current_index == 1 and #targets or current_index - 1
  end

  local cursor_row = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1]
  if direction > 0 then
    for index, target in ipairs(targets) do
      local anchor = target_anchor_row(view, target)
      if anchor and (anchor > cursor_row or cursor_on_collapsed_file_header(view, cursor_row, target)) then
        return index
      end
    end
    return 1
  end

  for index = #targets, 1, -1 do
    local anchor = target_anchor_row(view, targets[index])
    if anchor and anchor < cursor_row then
      return index
    end
  end
  return #targets
end
```

Preserve the active side in `View:move_hunk()`:

```lua
function View:move_hunk(direction)
  local targets = collect_hunk_targets(self)
  if #targets == 0 then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local side = self.win_sides[current_win]
  local target = targets[next_hunk_target_index(self, targets, direction)]
  if not target then
    return
  end

  self:expand_source_row(target.file, target.source_index)
  self:render()

  local row_index = display_row_for_source_index(self, target.file, target.source_index)
  if row_index then
    if side and valid_window(self[side .. "_win"]) then
      vim.api.nvim_set_current_win(self[side .. "_win"])
    end
    self:set_cursor_row(row_index)
  end
end
```

- [ ] **Step 4: Run the view spec and verify it passes**

Run:

```bash
make test PLENARY_PATH=deps/plenary.nvim
```

Expected: all tests pass.

- [ ] **Step 5: Commit collapsed-file hunk navigation**

Run:

```bash
git add lua/review-diff/init.lua tests/review_diff_view_spec.lua
git commit -m "fix: open collapsed files during hunk navigation"
```

---

### Task 4: Document and verify hunk navigation

**Files:**
- Modify: `README.md:58-62`
- Verify: `lua/review-diff/model.lua`, `lua/review-diff/init.lua`, `tests/review_diff_model_spec.lua`, `tests/review_diff_view_spec.lua`

**Interfaces:**
- Consumes: model and view behaviour from Tasks 1-3.
- Produces: README keybinding text matches runtime behaviour.

- [ ] **Step 1: Update README keybinding copy**

In `README.md`, change the review-tab keybinding row:

```diff
-| `]c` / `[c` | Next/previous changed line |
+| `]c` / `[c` | Next/previous hunk |
```

- [ ] **Step 2: Run format check**

Run:

```bash
make format-check
```

Expected: PASS.

If this fails with only formatting differences in changed Lua files, run:

```bash
make format
```

Then rerun:

```bash
make format-check
```

Expected: PASS.

- [ ] **Step 3: Run lint**

Run:

```bash
make lint
```

Expected: PASS.

- [ ] **Step 4: Run tests**

Run:

```bash
make test PLENARY_PATH=deps/plenary.nvim
```

Expected: PASS.

- [ ] **Step 5: Run full check**

Run:

```bash
make check PLENARY_PATH=deps/plenary.nvim
```

Expected: PASS.

- [ ] **Step 6: Check git status**

Run:

```bash
git status --short
```

Expected: only `README.md` is modified.

- [ ] **Step 7: Commit documentation**

Run:

```bash
git add README.md
git commit -m "docs: describe hunk navigation keymaps"
```

---

## Manual Verification

Run this after Task 4:

1. Open Neovim with the plugin installed locally.
2. Open a review with at least two files and one multi-line hunk.
3. In the review tab, use `]c` from the first line of a multi-line hunk.
4. Verify the cursor jumps to the next hunk, not the second line of the current hunk.
5. Collapse a changed file with `<Tab>`.
6. Use `]c` until the collapsed file is the next target.
7. Verify the file opens and the cursor lands on the first changed row of its hunk.
8. Repeat from the old pane and verify focus stays in the old pane.

## Final Handoff Checklist

- `git log --oneline -4` shows the task commits.
- `git status --short` is clean.
- `make check PLENARY_PATH=deps/plenary.nvim` passes.
- Manual verification result is reported, or the inability to run manual Neovim smoke testing is stated explicitly.

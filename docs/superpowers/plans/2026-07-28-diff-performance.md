# Diff Performance Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the review-diff viewer responsive on large diffs by eliminating O(n) scans in the render pipeline, deferring syntax highlighting, adding text caching, enabling incremental buffer updates for single-file operations, and streaming file processing asynchronously.

**Architecture:** Three phases: Phase 1 adds a row index hash map and defers expensive operations to eliminate O(n) scans from the hot path. Phase 2 replaces full buffer replacement with targeted `nvim_buf_set_lines` calls scoped to changed file/fold ranges. Phase 3 converts `model.build()` from synchronous to coroutine-batched processing so the viewer opens immediately and streams in content.

**Tech Stack:** Lua, Neovim API (`nvim_buf_set_extmark`, `nvim_buf_set_lines`, `nvim_buf_clear_namespace`), `vim.schedule()`, `vim.diff`, `vim.split`, `vim.deepcopy`

## Global Constraints

- Target Neovim 0.10+
- All changes are Lua-only; no new dependencies
- Existing tests under `tests/` must continue passing
- Follow existing code style: two-space indent, `local M = {}` module pattern, `---@param` annotations
- Run `make check` (format-check + lint + test) before committing
- Commands: `make test`, `make lint`, `make format`, `make check` (PLENARY_PATH=deps/plenary.nvim)
- Test framework: Plenary (Busted), run with `make test PLENARY_PATH=deps/plenary.nvim`

---

### Task 1: Build row index hash map on render

**Files:**
- Modify: `lua/review-diff/init.lua`

**Interfaces:**
- Produces: `self._row_index = { by_location = {}, by_file_header = {}, by_file_range = {} }` built in `View:render()`
- Rewrites: `View:location_row(location)`, `file_header_row(view, file)`, `display_row_for_source_index(view, file, source_index)`, `target_anchor_row(view, target)`, `source_index_for_display_row(row)`
- Adds: `View:_file_row_range(file_id) → { first = n, last = n }` helper

- [ ] Build `_row_index` at the end of `View:render()`, after `self.display_rows` is populated and hints are inserted:

```lua
-- Inside View:render(), after display_rows is fully built:
self._row_index = { by_location = {}, by_file_header = {}, by_file_range = {} }
for index, row in ipairs(self.display_rows) do
  if row.display_kind == "line" and row.file_id and row.source_row then
    local by_file = self._row_index.by_location[row.file_id]
    if not by_file then
      by_file = {}
      self._row_index.by_location[row.file_id] = by_file
    end
    for _, side in ipairs({ "old", "new" }) do
      local line = row.source_row[side .. "_line"]
      if line then
        by_file[side .. "_" .. line] = index
      end
    end
  elseif row.display_kind == "file_header" and row.file_id then
    self._row_index.by_file_header[row.file_id] = index
  end
  if row.file_id then
    local range = self._row_index.by_file_range[row.file_id]
    if not range then
      range = { first = index, last = index }
      self._row_index.by_file_range[row.file_id] = range
    else
      range.last = index
    end
  end
end
```

- [ ] Rewrite `View:location_row(location)` to use the index:

```lua
function View:location_row(location)
  local file = file_for_location(self.files, location)
  if not file then return nil, nil end
  local by_file = self._row_index and self._row_index.by_location and self._row_index.by_location[file.id]
  if not by_file then return nil, nil end
  local key = location.side .. "_" .. location.line
  local index = by_file[key]
  if not index then return nil, nil end
  return index, self.display_rows[index]
end
```

- [ ] Rewrite local function `file_header_row(view, file)`:

```lua
local function file_header_row(view, file)
  if view._row_index and view._row_index.by_file_header then
    return view._row_index.by_file_header[file.id]
  end
  for index, row in ipairs(view.display_rows) do
    if row.display_kind == "file_header" and row.file == file then
      return index
    end
  end
  return nil
end
```

- [ ] Rewrite local function `display_row_for_source_index(view, file, source_index)`:

```lua
local function display_row_for_source_index(view, file, source_index)
  local source_row = file.rows[source_index]
  if not source_row then return nil end
  local by_file = view._row_index and view._row_index.by_location and view._row_index.by_location[file.id]
  if by_file then
    -- Try new side first (changed lines are there), then old side
    for _, side in ipairs({ "new", "old" }) do
      local line = source_row[side .. "_line"]
      if line then
        local index = by_file[side .. "_" .. line]
        if index then return index end
      end
    end
    return nil
  end
  for index, row in ipairs(view.display_rows) do
    if row.display_kind == "line" and row.file == file and row.source_row == source_row then
      return index
    end
  end
  return nil
end
```

- [ ] Rewrite local function `target_anchor_row(view, target)`:

```lua
local function target_anchor_row(view, target)
  local exact = display_row_for_source_index(view, target.file, target.source_index)
  if exact then return exact end
  for index, row in ipairs(view.display_rows) do
    if row.display_kind == "fold" and row.file == target.file
      and target.source_index >= row.fold.first_row
      and target.source_index <= row.fold.last_row then
      return index
    end
  end
  return file_header_row(view, target.file)
end
```

Note: `target_anchor_row` still uses the linear scan for fold rows since we don't index folds. Acceptable because fold count is far smaller than line count.

- [ ] Add `View:_file_row_range(file_id)` helper:

```lua
function View:_file_row_range(file_id)
  if self._row_index and self._row_index.by_file_range then
    return self._row_index.by_file_range[file_id]
  end
  return nil
end
```

- [ ] In `lua/review-diff/model.lua`, annotate each source row with its index inside `M.build_file()`. After the `result.rows` loop:

```lua
for index, source_row in ipairs(result.rows) do
  source_row._source_index = index
end
```

- [ ] Then rewrite local function `source_index_for_display_row(row)` in `init.lua`:

```lua
local function source_index_for_display_row(row)
  if not row or row.display_kind ~= "line" or not row.source_row then
    return nil
  end
  return row.source_row._source_index
end
```

- [ ] Run existing tests: `make test PLENARY_PATH=deps/plenary.nvim`
- [ ] Run lint: `make lint`
- [ ] Run format-check: `make format-check`
- [ ] Run `make check` to confirm everything passes
- [ ] Commit: `git add lua/review-diff/init.lua lua/review-diff/model.lua && git commit -m "perf: add row index hash map for O(1) display row lookups"`

---

### Task 2: Defer syntax highlighting to async

**Files:**
- Modify: `lua/review-diff/init.lua`

**Interfaces:**
- Consumes: `View:render()` from Task 1
- Changes: `self:apply_syntax()` moves from synchronous in `View:render()` to `vim.schedule()` callback

- [ ] In `View:render()`, remove the `self:apply_syntax()` call from the synchronous block:

```lua
function View:render()
  -- ... existing: build display_rows, hints, set lines, highlights, annotations, cursorline ...
  self:emit("rendered")
  vim.schedule(function()
    if not self.closed then
      self:apply_syntax()
    end
  end)
end
```

- [ ] Guard `apply_syntax()` against `self.closed` (already done via the `vim.schedule` check)
- [ ] Run existing tests: `make test PLENARY_PATH=deps/plenary.nvim`
- [ ] Verify the Tree-sitter highlight test still passes (`review_diff_view_spec.lua:127`):
  ```bash
  PLENARY_PATH=deps/plenary.nvim nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua' }"
  ```
  Note: The syntax test checks extmarks synchronously. Since syntax is now deferred via `vim.schedule()`, the test will need `vim.wait(100, ...)` to wait for the async callback. Update the test:

```lua
-- In "projects Tree-sitter highlights into the aggregate buffers":
vim.wait(200, function() return #vim.api.nvim_buf_get_extmarks(view.new_buf, syntax_ns, 0, -1, {}) > 0 end)
local marks = vim.api.nvim_buf_get_extmarks(view.new_buf, syntax_ns, 0, -1, {})
```

- [ ] Commit: `git add lua/review-diff/init.lua tests/review_diff_view_spec.lua && git commit -m "perf: defer syntax highlighting to async schedule"`

---

### Task 3: Cache display row text output

**Files:**
- Modify: `lua/review-diff/render.lua`

**Interfaces:**
- Consumes: `render.text()` signature unchanged
- Adds: `M._text_cache = {}`, `M.clear_text_cache()`
- Produces: Cached text strings keyed by `(display_kind, file_id, side, width, source_row_hash)`

- [ ] Add cache table at module level:

```lua
M._text_cache = {}
```

- [ ] Modify `M.text(row, side, width, opts)` to check cache:

```lua
function M.text(row, side, width, opts)
  if row.display_kind == "hint" then
    return row.hint_text or ""
  end
  if row.display_kind == "empty" then
    return "  " .. row.text
  end

  local cache_key
  if width then
    local prefix = row.display_kind
    if row.display_kind == "line" then
      local src = row.source_row
      prefix = string.format("%s:%s:%d:%d:%s:%s",
        row.display_kind, row.file_id, src.old_line or 0, src.new_line or 0,
        src.old_text or "", src.new_text or "")
    elseif row.display_kind == "file_header" then
      prefix = string.format("%s:%s:%s", row.display_kind, row.file_id, tostring(row.collapsed))
    elseif row.display_kind == "fold" then
      prefix = string.format("%s:%s:%d:%d", row.display_kind, row.file_id, row.fold.first_row, row.fold.last_row)
    elseif row.display_kind == "metadata" then
      prefix = string.format("%s:%s:%s", row.display_kind, row.file_id, row.text or "")
    end
    cache_key = string.format("%s:%s:%d", prefix, side, width)
    local cached = M._text_cache[cache_key]
    if cached then
      return cached
    end
  end

  -- ... existing text computation logic (unchanged) ...

  if cache_key then
    M._text_cache[cache_key] = result -- result is the computed text
  end
  return result
end
```

Wait, this is getting complex for string-based keys. Let me use a simpler approach — structured key:

```lua
function M.text(row, side, width, opts)
  if row.display_kind == "hint" then
    return row.hint_text or ""
  end
  if row.display_kind == "empty" then
    return "  " .. row.text
  end

  local cache_key
  if width then
    cache_key = { row.display_kind, row.file_id, side, width }
    if row.display_kind == "line" then
      cache_key[5] = row.source_row
    elseif row.display_kind == "file_header" then
      cache_key[5] = row.collapsed
    elseif row.display_kind == "fold" then
      cache_key[5] = row.fold.first_row
      cache_key[6] = row.fold.last_row
    elseif row.display_kind == "metadata" then
      cache_key[5] = row.text
    end
    local key_str = table.concat(cache_key, "\0")
    local cached = M._text_cache[key_str]
    if cached then
      return cached
    end
  end

  -- ... existing computation (unchanged) ...
  local result = -- ... (the computed text string)

  if cache_key then
    M._text_cache[table.concat(cache_key, "\0")] = result
  end
  return result
end
```

Actually, let me just use a simpler keying approach that's clearly correct:

```lua
M._text_cache = {}
M._text_cache_generation = 0

function M.clear_text_cache()
  M._text_cache = {}
  M._text_cache_generation = M._text_cache_generation + 1
end

function M.cache_text_key(row, side, width)
  -- Build a simple string key covering all properties that affect output
  local parts = { row.display_kind, side, tostring(width) }
  if row.display_kind == "line" and row.source_row then
    local s = row.source_row
    parts[#parts + 1] = tostring(s.old_line)
    parts[#parts + 1] = tostring(s.new_line)
    parts[#parts + 1] = s.old_text or ""
    parts[#parts + 1] = s.new_text or ""
  elseif row.display_kind == "file_header" then
    parts[#parts + 1] = tostring(row.collapsed)
  elseif row.display_kind == "fold" then
    parts[#parts + 1] = tostring(row.fold.first_row)
    parts[#parts + 1] = tostring(row.fold.last_row)
  elseif row.display_kind == "metadata" then
    parts[#parts + 1] = row.text or ""
  end
  return table.concat(parts, "\0")
end
```

Wait, this is getting overly complex for a plan. Let me simplify:

- [ ] Add `M._text_cache = {}` at the top of `render.lua`
- [ ] Modify `M.text()` to check cache before computing. Key format: concatenate `display_kind`, `file_id`, `side`, `width`, and row-specific fields with `"\0"` separator (Lua strings are binary-safe):

```lua
function M.text(row, side, width, opts)
  if row.display_kind == "hint" then return row.hint_text or "" end
  if row.display_kind == "empty" then return "  " .. row.text end

  local cache_key
  if width then
    local parts = { row.display_kind, tostring(row.file_id), side, tostring(width) }
    if row.display_kind == "line" and row.source_row then
      local s = row.source_row
      parts[#parts + 1] = tostring(s.old_line)
      parts[#parts + 1] = tostring(s.new_line)
      parts[#parts + 1] = s.old_text or "\0nil"
      parts[#parts + 1] = s.new_text or "\0nil"
    elseif row.display_kind == "file_header" then
      parts[#parts + 1] = tostring(row.collapsed)
    elseif row.display_kind == "fold" then
      parts[#parts + 1] = tostring(row.fold.first_row)
      parts[#parts + 1] = tostring(row.fold.last_row)
    elseif row.display_kind == "metadata" then
      parts[#parts + 1] = row.text or ""
    end
    cache_key = table.concat(parts, "\0")
    local cached = M._text_cache[cache_key]
    if cached then return cached end
  end

  -- ... existing text computation logic (unchanged) ...

  if cache_key then
    M._text_cache[cache_key] = result
  end
  return result
end
```

- [ ] Add `M.clear_text_cache()` that resets `M._text_cache = {}`
- [ ] Call `M.clear_text_cache()` from `View:replace()` (when input changes) and from the `WinResized` autocmd callback (when width changes)
- [ ] On `View:replace()`, iterator through display_rows once to warm the cache (avoids cold-start latency on first toggle)
- [ ] Run `make check` to verify tests pass and formatting/linting is clean
- [ ] Commit: `git add lua/review-diff/render.lua lua/review-diff/init.lua && git commit -m "perf: cache display row text output"`

---

### Task 4: Skip re-render on hunk navigation when target is visible

**Files:**
- Modify: `lua/review-diff/init.lua`

**Interfaces:**
- Consumes: `display_row_for_source_index(view, file, source_index)` from Task 1 (now O(1))
- Changes: `View:move_hunk(direction)` short-circuits when target is already visible

- [ ] At the top of `View:move_hunk(direction)`, after computing the target index, check if the target row is already in `display_rows`:

```lua
function View:move_hunk(direction)
  local targets = collect_hunk_targets(self)
  if #targets == 0 then return end

  local current_win = vim.api.nvim_get_current_win()
  local side = self.win_sides[current_win]
  local target = targets[next_hunk_target_index(self, targets, direction)]
  if not target then return end

  -- Check if target is already visible
  local row_index = display_row_for_source_index(self, target.file, target.source_index)
  if row_index then
    if side and valid_window(self[side .. "_win"]) then
      vim.api.nvim_set_current_win(self[side .. "_win"])
    end
    self:set_cursor_row(row_index)
    return
  end

  -- Need to expand a collapsed section first
  self:expand_source_row(target.file, target.source_index)
  self:render()
  row_index = display_row_for_source_index(self, target.file, target.source_index)
  if row_index then
    if side and valid_window(self[side .. "_win"]) then
      vim.api.nvim_set_current_win(self[side .. "_win"])
    end
    self:set_cursor_row(row_index)
  end
end
```

- [ ] Run existing hunk navigation tests: `make test PLENARY_PATH=deps/plenary.nvim`
- [ ] Run `make check`
- [ ] Commit: `git add lua/review-diff/init.lua && git commit -m "perf: skip re-render on hunk navigation when target is visible"`

---

### Task 5: Track diff buffers for targeted extmark cleanup

**Files:**
- Modify: `lua/herdr-review/session.lua`

**Interfaces:**
- Consumes: `view.old_buf`, `view.new_buf` from viewer
- Changes: `state.diff_buffers` tracks specific scratch buffer numbers, `reset()` clears only those

- [ ] Add `state.diff_buffers = {}` to the module-level `state` table
- [ ] In `load_session()`, after setting `state.current_view`, record the scratch buffer numbers:

```lua
function M.load_session(range, view)
  local comments, err = storage.get_comments(range)
  if not comments then
    report_storage_error(err)
    return false
  end

  state.current_range = range
  state.current_view = view or viewer.current()
  if state.current_view then
    -- Track diff buffers for efficient cleanup
    state.diff_buffers = {}
    for _, side in ipairs({ "old", "new" }) do
      local bufnr = state.current_view[side .. "_buf"]
      if bufnr then
        table.insert(state.diff_buffers, bufnr)
      end
    end
    apply_comments(state.current_view, comments, range)
  end
  return true
end
```

- [ ] Rewrite `M.reset()` to use tracked buffers instead of `nvim_list_bufs()`:

```lua
function M.reset()
  state.current_range = nil
  state.current_view = nil
  state.stale_ids = {}
  state.resolved_locations = {}
  pending_view_state = nil
  for _, bufnr in ipairs(state.diff_buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.clear_extmarks(bufnr)
    end
  end
  state.diff_buffers = {}
end
```

- [ ] Run session tests: `make test PLENARY_PATH=deps/plenary.nvim`
- [ ] Run `make check`
- [ ] Commit: `git add lua/herdr-review/session.lua && git commit -m "perf: track diff buffers for targeted extmark cleanup"`

---

### Task 6: Per-file display row caching

**Files:**
- Modify: `lua/review-diff/model.lua`

**Interfaces:**
- Consumes: `model.visible_rows(file, context_lines)`
- Produces: Cached `file._visible_rows` and `file._visible_context_lines`, invalidated in `build_file()`

- [ ] In `M.visible_rows(file, context_lines)`, check for a cached result:

```lua
function M.visible_rows(file, context_lines)
  context_lines = context_lines or 3
  if file._visible_rows and file._visible_context_lines == context_lines then
    return file._visible_rows
  end
  -- ... existing computation (unchanged) ...
  file._visible_rows = visible
  file._visible_context_lines = context_lines
  return visible
end
```

- [ ] In `M.build_file(file, opts)`, invalidate the cache when rebuilding:

```lua
function M.build_file(file, opts)
  -- ... existing setup ...
  file._visible_rows = nil
  file._visible_context_lines = nil
  -- ... rest of build (unchanged) ...
  return result
end
```

- [ ] Run model tests: `make test PLENARY_PATH=deps/plenary.nvim`
- [ ] Run `make check`
- [ ] Commit: `git add lua/review-diff/model.lua && git commit -m "perf: cache per-file visible rows"`

---

### Task 7: Incremental buffer update for file toggle

**Files:**
- Modify: `lua/review-diff/init.lua`

**Interfaces:**
- Consumes: `View:_file_row_range(file_id)` from Task 1, `model.visible_rows()` caching from Task 6
- Changes: `View:toggle_file_at_cursor()` replaces rows in `display_rows` and both buffers incrementally instead of full `render()`

- [ ] Add `View:_build_file_rows(file_id) → display_rows[]` helper that generates the display row slice for one file based on current state:

```lua
function View:_build_file_rows(file_id)
  local rows = {}
  for _, file in ipairs(self.files) do
    if file.id == file_id then
      table.insert(rows, {
        display_kind = "file_header",
        file = file,
        file_id = file.id,
        collapsed = self.state.collapsed_files[file.id] == true,
      })
      if not self.state.collapsed_files[file.id] then
        if file.binary or file.too_large then
          table.insert(rows, {
            display_kind = "metadata",
            file = file,
            file_id = file.id,
            text = file.binary and "binary file changed" or "file is too large to diff",
          })
        else
          local visible_rows = model.visible_rows(file, self.state.context_lines)
          for _, row in ipairs(visible_rows) do
            if row.kind == "fold" and self.state.expanded_folds[string.format("%s:%d:%d", file.id, row.first_row, row.last_row)] then
              for source_index = row.first_row, row.last_row do
                table.insert(rows, {
                  display_kind = "line",
                  file = file,
                  file_id = file.id,
                  source_row = file.rows[source_index],
                })
              end
            elseif row.kind == "fold" then
              table.insert(rows, {
                display_kind = "fold",
                file = file,
                file_id = file.id,
                fold = row,
                expanded = false,
              })
            else
              table.insert(rows, {
                display_kind = "line",
                file = file,
                file_id = file.id,
                source_row = row,
              })
            end
          end
        end
      end
      break
    end
  end
  return rows
end
```

- [ ] Rewrite `View:toggle_file_at_cursor()` to use incremental update:

```lua
function View:toggle_file_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
  local row = self.display_rows[cursor[1]]
  if not row or not row.file_id then return end
  local file_id = row.file_id

  local file_range = self:_file_row_range(file_id)
  if not file_range then return end

  -- Toggle state
  self.state.collapsed_files[file_id] = not self.state.collapsed_files[file_id]

  -- Build new rows for this file
  local new_rows = self:_build_file_rows(file_id)
  local old_count = file_range.last - file_range.first + 1
  local new_count = #new_rows

  -- Replace in display_rows
  for i = old_count, 1, -1 do
    table.remove(self.display_rows, file_range.first)
  end
  for i, r in ipairs(new_rows) do
    table.insert(self.display_rows, file_range.first + i - 1, r)
  end

  -- Rebuild row index (full rebuild since positions shifted)
  -- This is a trade-off: rebuilding the index is O(rows) but cheap compared to full render

  -- Update buffers with targeted nvim_buf_set_lines
  for _, side in ipairs({ "old", "new" }) do
    local bufnr = self[side .. "_buf"]
    local width = vim.api.nvim_win_get_width(self[side .. "_win"])
    local lines = {}
    for _, r in ipairs(new_rows) do
      table.insert(lines, render.text(r, side, width, self.options))
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, file_range.first - 1, file_range.first - 1 + old_count, false, lines)
    vim.bo[bufnr].modifiable = false

    -- Clear highlights for the replaced range
    vim.api.nvim_buf_clear_namespace(bufnr, render_ns, file_range.first - 1, file_range.first - 1 + old_count)

    -- Re-apply highlights for the new rows only
    for local_index, r in ipairs(new_rows) do
      local global_index = file_range.first + local_index - 1
      local line_hl, inline = render.highlight(r, side, self.options)
      if line_hl then
        local col_start = 0
        if r.display_kind == "line" then
          col_start = render.source_prefix_width(r, side, self.options)
        end
        vim.api.nvim_buf_set_extmark(bufnr, render_ns, global_index - 1, col_start, {
          end_row = global_index,
          end_col = 0,
          hl_group = line_hl,
          hl_eol = true,
          priority = 50,
        })
      end
      if inline and inline.finish > inline.start then
        vim.api.nvim_buf_set_extmark(bufnr, render_ns, global_index - 1, inline.start, {
          end_row = global_index - 1,
          end_col = inline.finish,
          hl_group = inline.hl_group,
          priority = 80,
        })
      end
    end
  end

  -- Rebuild row index after all changes settle
  self:_rebuild_row_index()
  self:apply_annotations()
  self:update_cursorline()
  self:emit("rendered")
end
```

- [ ] Add `View:_rebuild_row_index()` method that contains the index building loop from Task 1 (extracted from `render()`)
- [ ] In `View:render()`, call `self:_rebuild_row_index()` instead of inline index building
- [ ] Position cursor: if file was collapsed, place cursor on its header row
- [ ] Run `make check`
- [ ] Commit: `git add lua/review-diff/init.lua && git commit -m "perf: incremental buffer update for file toggle"`

---

### Task 8: Incremental buffer update for fold toggle

**Files:**
- Modify: `lua/review-diff/init.lua`

**Interfaces:**
- Consumes: `View:_file_row_range()`, `View:_build_file_rows()` from Task 7, `View:_rebuild_row_index()` from Task 7
- Changes: `View:toggle_fold_at_cursor()` only rebuilds the affected file's rows (reuses `_build_file_rows` logic)

- [ ] Rewrite `View:toggle_fold_at_cursor()` to use incremental file-level update:

```lua
function View:toggle_fold_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
  local row = self.display_rows[cursor[1]]
  if not row then return end
  if row.display_kind == "file_header" then
    self:toggle_file_at_cursor()
  elseif row.display_kind == "fold" then
    local file_id = row.file_id
    local target_first = row.fold.first_row
    local target_last = row.fold.last_row
    local key = string.format("%s:%d:%d", file_id, target_first, target_last)
    local was_expanded = self.state.expanded_folds[key]
    self.state.expanded_folds[key] = not was_expanded

    local file_range = self:_file_row_range(file_id)
    if not file_range then return end

    local new_rows = self:_build_file_rows(file_id)
    local old_count = file_range.last - file_range.first + 1
    local new_count = #new_rows

    -- Replace in display_rows
    for i = old_count, 1, -1 do
      table.remove(self.display_rows, file_range.first)
    end
    for i, r in ipairs(new_rows) do
      table.insert(self.display_rows, file_range.first + i - 1, r)
    end

    -- Update buffers (same pattern as Task 7)
    for _, side in ipairs({ "old", "new" }) do
      local bufnr = self[side .. "_buf"]
      local width = vim.api.nvim_win_get_width(self[side .. "_win"])
      local lines = {}
      for _, r in ipairs(new_rows) do
        table.insert(lines, render.text(r, side, width, self.options))
      end
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, file_range.first - 1, file_range.first - 1 + old_count, false, lines)
      vim.bo[bufnr].modifiable = false
      vim.api.nvim_buf_clear_namespace(bufnr, render_ns, file_range.first - 1, file_range.first - 1 + old_count)
      -- Re-apply highlights for changed range
      for local_index, r in ipairs(new_rows) do
        local global_index = file_range.first + local_index - 1
        local line_hl, inline = render.highlight(r, side, self.options)
        if line_hl then
          local col_start = 0
          if r.display_kind == "line" then
            col_start = render.source_prefix_width(r, side, self.options)
          end
          vim.api.nvim_buf_set_extmark(bufnr, render_ns, global_index - 1, col_start, {
            end_row = global_index, end_col = 0, hl_group = line_hl, hl_eol = true, priority = 50,
          })
        end
        if inline and inline.finish > inline.start then
          vim.api.nvim_buf_set_extmark(bufnr, render_ns, global_index - 1, inline.start, {
            end_row = global_index - 1, end_col = inline.finish, hl_group = inline.hl_group, priority = 80,
          })
        end
      end
    end

    self:_rebuild_row_index()
    self:apply_annotations()
    self:update_cursorline()
    self:emit("rendered")

    if was_expanded then
      for index, display_row in ipairs(self.display_rows) do
        if display_row.display_kind == "fold"
          and display_row.file_id == file_id
          and display_row.fold.first_row == target_first
          and display_row.fold.last_row == target_last then
          self:set_cursor_row(index)
          break
        end
      end
    end
  end
end
```

**Note:** This duplicates rendering logic from Task 7. Consider extracting a shared `View:_replace_file_rows(file_id, new_rows)` helper that both `toggle_file_at_cursor()` and `toggle_fold_at_cursor()` call.

- [ ] Run `make check`
- [ ] Verify manually: open a diff with multiple files, toggle folds, confirm cursor position is correct
- [ ] Commit: `git add lua/review-diff/init.lua && git commit -m "perf: incremental buffer update for fold toggle"`

---

### Task 9: Syntax highlight partial invalidation

**Files:**
- Modify: `lua/review-diff/init.lua`

**Interfaces:**
- Consumes: `apply_syntax()` from Task 2, `_file_row_range()` from Task 1
- Produces: `View:apply_syntax(changed_file_ids)` accepts optional filter

- [ ] Add optional `changed_file_ids` parameter to `View:apply_syntax()`:

```lua
function View:apply_syntax(changed_file_ids)
  for _, side in ipairs({ "old", "new" }) do
    if changed_file_ids then
      -- Clear only rows for changed files
      for file_id, _ in pairs(changed_file_ids) do
        local range = self:_file_row_range(file_id)
        if range then
          vim.api.nvim_buf_clear_namespace(self[side .. "_buf"], syntax_ns, range.first - 1, range.last)
        end
      end
    else
      vim.api.nvim_buf_clear_namespace(self[side .. "_buf"], syntax_ns, 0, -1)
    end
  end

  local syntax_options = self.options.syntax
  if syntax_options == false or (type(syntax_options) == "table" and syntax_options.enabled == false) then
    return
  end

  for _, side in ipairs({ "old", "new" }) do
    local bufnr = self[side .. "_buf"]
    for _, file in ipairs(self.files) do
      if not changed_file_ids or changed_file_ids[file.id] then
        -- ... existing per-file syntax application (unchanged) ...
      end
    end
  end
end
```

- [ ] In the incremental toggle methods from Tasks 7 and 8, call `self:apply_syntax({ [file_id] = true })` instead of relying on a full `vim.schedule`-based deferred syntax
- [ ] Run syntax test: `make test PLENARY_PATH=deps/plenary.nvim`
- [ ] Run `make check`
- [ ] Commit: `git add lua/review-diff/init.lua && git commit -m "perf: partial syntax highlight invalidation for incremental toggles"`

---

### Task 10: Async model building with coroutine batching

**Files:**
- Modify: `lua/review-diff/model.lua`

**Interfaces:**
- Produces: `model.build_async(files, opts, on_file, on_done, generation_check)`
- Consumes: Existing `model.build_file()` (unchanged)

- [ ] Add `M.build_async(files, opts, on_file, on_done, generation_check)`:

```lua
function M.build_async(files, opts, on_file, on_done, generation_check)
  opts = opts or {}
  local result = { files = {} }
  local i = 0
  local batch_size = 3

  local function process_batch()
    if generation_check and not generation_check() then return end
    local batch_end = math.min(i + batch_size, #files)
    while i < batch_end do
      i = i + 1
      local file = M.build_file(files[i], opts)
      table.insert(result.files, file)
      if on_file then on_file(file, i, #files) end
    end
    if i < #files then
      vim.schedule(process_batch)
    else
      table.sort(result.files, function(left, right)
        return (left.new_path or left.old_path or "") < (right.new_path or right.old_path or "")
      end)
      if on_done then on_done(result) end
    end
  end

  vim.schedule(process_batch)
end
```

- [ ] Run model tests: `make test PLENARY_PATH=deps/plenary.nvim`
- [ ] Run `make check`
- [ ] Commit: `git add lua/review-diff/model.lua && git commit -m "feat: add async model.build_async with coroutine batching"`

---

### Task 11: Progressive viewer population

**Files:**
- Modify: `lua/review-diff/init.lua`
- Modify: `lua/herdr-review/init.lua`

**Interfaces:**
- Consumes: `model.build_async()` from Task 10
- Changes: `View:replace()` uses async build, fires `"ready"` immediately with placeholders; progressive file streaming

- [ ] In `View:replace()`, replace synchronous `model.build()` with async:

```lua
function View:replace(input, opts)
  local snapshot = opts and opts.state or self:capture_state()
  local same_review = snapshot and snapshot.review_id == input.review_id
  self.input = vim.deepcopy(input)

  -- Start with empty files, show immediately
  self.files = {}
  self.syntax_cache = {}
  self.state.context_lines = self.options.context_lines
  self.state.empty_text = input.empty_text or "No changes"
  self.state.collapsed_files = {}
  self.state.expanded_folds = same_review and vim.deepcopy(snapshot.expanded_folds or {}) or {}

  self._build_generation = (self._build_generation or 0) + 1
  local generation = self._build_generation

  local total = #(input.files or {})
  if total == 0 then
    self:render()
    self:emit("ready")
    return
  end

  self.hint_text = "Resolving diffs…"
  self:render()
  self:emit("ready")  -- Viewer is interactive immediately

  model.build_async(input.files, self.options,
    -- on_file: append a completed file and re-render
    function(file, current, _)
      if self._build_generation ~= generation then return end
      table.insert(self.files, file)
      self.state.collapsed_files[file.id] = self.options.collapse_on_open
      self.hint_text = string.format(
        "Processing %d/%d… %s", current, total,
        file.new_path or file.old_path or ""
      )
      self:render()
    end,
    -- on_done: final render with sorted files
    function(result)
      if self._build_generation ~= generation then return end
      self.files = result.files
      for _, file in ipairs(self.files) do
        if self.state.collapsed_files[file.id] == nil then
          self.state.collapsed_files[file.id] = saved ~= nil and saved or self.options.collapse_on_open
        end
      end
      self.hint_text = nil
      self:render()
      self:place_initial_cursor()
      if same_review then
        self:restore_state(snapshot)
      end
    end,
    -- generation check
    function() return self._build_generation == generation end
  )
end
```

- [ ] In `lua/herdr-review/init.lua`, remove the `session.on_view_opened()` call from the `"ready"` event handler (since `ready` now fires before files are resolved). Instead, listen for a new event or check. But wait — the session load needs comment locations to be resolvable. Let's defer session load to after the progressive build completes:

Add a `"files_ready"` event that fires from `on_done`:

```lua
-- In on_done callback above, after render and place_initial_cursor:
self:emit("files_ready")
```

- [ ] In `lua/herdr-review/init.lua:attach_view()`, wire the `"files_ready"` event for session loading:

```lua
-- Replace the "ready" handler in attach_view:
local function attach_ready(view, pending_attached)
  if pending_attached then
    session.on_view_opened(view)
  end
end

-- Register the "ready" event first (for pending state):
local pending_attached = false
view:on("ready", function()
  -- On initial open (empty files), just prepare
  pending_attached = true
end)

-- Then register "files_ready" for actual session load:
view:on("files_ready", function()
  if pending_attached then
    pending_attached = false
    session.on_view_opened(view)
  end
end)
```

Wait, this changes the attach_view flow. Let me reconsider. Actually, for the non-progressive case (M.open without replace), the files are empty initially, then fill in progressively. For the replace case, it's the same. The key insight: `session.on_view_opened()` needs comments to be resolvable against actual file content. So we should defer it.

But there's a subtlety: when the view is reused (M.open on an existing active_view), `replace()` is called, which now triggers progressive build. The `ready` event fires immediately. But the herdr-review code in `start_review()` calls `view:replace()` and doesn't listen for `files_ready` — session load happens via the `ready` event in `attach_view`.

Let me simplify: instead of a new event, just modify the `attach_view` handler:

- [ ] In `lua/herdr-review/init.lua:attach_view()`:

```lua
local function attach_view(view)
  local session_loaded = false
  view:on("ready", function()
    if not session_loaded then
      session.on_view_opened(view)
      session_loaded = true
    end
  end)
  -- ... rest of wiring ...
end
```

This means on first `ready` (empty files), session will try to load but comments referencing files not yet built will become stale. That's OK — they'll be re-resolved on next `ready` when the file arrives. Actually, session load writes stale comments back. This is problematic.

Better approach: Skip session load in `ready` and do it in a `files_ready` event or after checking if files are populated. Actually, let's just keep the current "ready" timing but ensure that `ready` fires WHEN files are fully resolved. In `replace()`, the `ready` event already fires at the end of the synchronous case. For progressive, we fire `ready` at the beginning AND after done.

The simplest fix: in the `on_done` callback of `build_async`, don't emit `files_ready` — instead just let the existing `ready` handler deal with the final state. But the existing handler fires from `replace()` at the start...

OK let me take a cleaner approach. The progressive view should:
1. Fire `ready` at the start (so the tab opens and is interactive)
2. The session should only load when files are actually present

In `lua/herdr-review/init.lua`, the `ready` handler doesn't currently check if files are present. Let me add a guard:

```lua
view:on("ready", function()
  if view.files and #view.files > 0 then
    session.on_view_opened(view)
  end
end)
```

And in the progressive `on_done`, emit `ready` again:

```lua
function(result)
  if self._build_generation ~= generation then return end
  self.files = result.files
  -- ... set state ...
  self.hint_text = nil
  self:render()
  self:place_initial_cursor()
  if same_review then self:restore_state(snapshot) end
  self:emit("ready")  -- Re-emit with files present
end
```

This way the session loads only when files arrive. The first `ready` (empty files) is a no-op for session.

Let me update the plan task for this.

- [ ] Actually, this is getting too complex for the plan. Let me simplify Task 11 significantly:

Just add the `files_ready` event. The `ready` event semantics don't change for the non-progressive path (M.open with pre-built files). For the progressive path, session loading moves to `files_ready`.

```lua
-- In View:replace():
  -- ...on_done...
  self:emit("files_ready")
end
```

```lua
-- In M.open() (non-progressive), emit files_ready after ready:
view:emit("ready")
view:emit("files_ready")
```

```lua
-- In herdr-review/init.lua attach_view():
view:on("files_ready", function()
  session.on_view_opened(view)
end)
```

Remove the session load from `ready`. This is clean and explicit.

- [ ] Run `make check`
- [ ] Manual smoke test: `:ReviewDiff main...HEAD` — verify files stream in progressively, comments load after all files resolved
- [ ] Commit: `git add lua/review-diff/init.lua lua/herdr-review/init.lua && git commit -m "feat: progressive viewer population with async model building"`

---

### Task 12: File size threshold for diff computation

**Files:**
- Modify: `lua/review-diff/init.lua`
- Modify: `lua/review-diff/model.lua`

**Interfaces:**
- Produces: `max_file_size` config option (default 1_000_000), `model.build_file()` skips diff for oversized files

- [ ] Add `max_file_size = 1000000` to `DEFAULT_OPTIONS` in `init.lua`
- [ ] In `model.build_file()`, before calling `vim.diff`, check total size:

```lua
function M.build_file(file, opts)
  opts = opts or {}
  local old_lines = split_lines(file.old_text)
  local new_lines = split_lines(file.new_text)
  local result = vim.deepcopy(file)
  -- ... existing id, old_lines, new_lines, rows, hunks setup ...

  if result.binary or result.too_large then
    return result
  end

  local total_size = (file.old_text and #file.old_text or 0) + (file.new_text and #file.new_text or 0)
  if total_size > (opts.max_file_size or 1000000) then
    result.too_large = true
    result.rows = {}
    result.hunks = {}
    return result
  end

  -- ... existing vim.diff call ...
end
```

- [ ] Run `make check`
- [ ] Commit: `git add lua/review-diff/init.lua lua/review-diff/model.lua && git commit -m "feat: skip diff computation for files exceeding size threshold"`

---

### Task 13: Generation counter for stale progressive builds

**Files:**
- Modify: `lua/review-diff/init.lua`

**Interfaces:**
- Consumes: `_build_generation` counter on View (already added in Task 11)
- Produces: Stale callback protection in `View:replace()`

- [ ] The generation counter is already defined in Task 11 (`self._build_generation`). Verify both `on_file` and `on_done` callbacks check it:

```lua
-- In on_file:
if self._build_generation ~= generation then return end

-- In on_done:
if self._build_generation ~= generation then return end
```

- [ ] Ensure `View:replace()` increments `_build_generation` before starting the async build
- [ ] Verify via manual test: open a large diff, immediately open another — only the second one's content should appear
- [ ] Run `make check`
- [ ] Commit: `git add lua/review-diff/init.lua && git commit -m "fix: prevent stale callbacks from overwriting active progressive build"`

---

### Task 14: Integration verification

**Files:**
- No changes; verify all phases work together

- [ ] Run full test suite: `make test PLENARY_PATH=deps/plenary.nvim`
- [ ] Run lint: `make lint`
- [ ] Run format check: `make format-check`
- [ ] Manually smoke test with large diff (e.g., `main...HEAD` on a branch with many changes):
  - Verify Loading indicator is brief
  - Verify files appear progressively
  - Verify toggling files/folds is responsive and cursor position correct
  - Verify hunk navigation is instant when no expansion needed
  - Verify syntax highlighting appears after content
  - Verify comments/annotations load and display correctly
  - Verify session state restores correctly on close/reopen
  - Verify window resize still works
  - Verify refresh (`R`) works with stale build cancellation
  - Verify comment create/edit/delete works after progressive load
- [ ] Commit if any fixes were needed: `git commit -m "fix: integration fixes for performance optimization"`

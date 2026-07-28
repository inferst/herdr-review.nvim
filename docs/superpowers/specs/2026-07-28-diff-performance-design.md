# Diff View Performance Optimization Design

**Date:** 2026-07-28
**Status:** Design approved, awaiting implementation plan

## Problem

Opening large diffs in the `review-diff` viewer is slow. Users report:

1. **Long loading phase** — the Loading indicator stays visible while `git.resolve()` and
   `model.build()` (which runs `vim.diff` on every file) complete synchronously.
2. **Sluggish interactivity** — opening/closing files, navigating hunks, toggling folds
   all trigger a full `view:render()`, which rebuilds every display row, replaces entire
   buffer content, and re-applies all highlights, syntax, and annotations from scratch.

## Root Causes

The viewer's `render()` method (`review-diff/init.lua:414-468`) is called on nearly
every user action and performs O(n) work where n is the total number of display rows:

| Bottleneck | Location | Cost |
|---|---|---|
| `location_row()` linear scan | `init.lua:579` | O(rows) per syntax span + per annotation |
| Full buffer replacement (`nvim_buf_set_lines`) | `init.lua:434` | O(rows) buffer I/O per render |
| Syntax highlight application (`apply_syntax`) | `init.lua:366` | O(files × spans × display_rows) |
| Annotation application (`apply_annotations`) | `init.lua:488` | O(annotations × display_rows) |
| `model.build()` synchronous `vim.diff` | `model.lua:175` | CPU-intensive per file, blocks UI during load |
| `render()` called on every toggle/navigate | `init.lua:763,789,817,827,841,1011` | Full rebuild for single-file operations |

Additionally, `herdr-review/session.lua` contributes minor overhead:

- `reset()` scans all buffers via `vim.api.nvim_list_bufs()` to clear extmarks
- Session reload after each comment mutation triggers a full re-render

## Solution Overview

Three phases, implemented sequentially:

1. **Targeted fixes** — eliminate O(n) scans, defer syntax, cache text. ~2-5x improvement.
2. **Incremental rendering** — targeted buffer updates for single-file operations. Eliminates
   re-render overhead for toggles/navigation.
3. **Async model building + progressive loading** — stream files into the viewer, show
   content immediately while `vim.diff` runs in batches.

---

## Phase 1: Targeted Fixes

### 1.1 Row index hash map

**What:** Build a lookup table on each `render()` that maps `(file_id, side, line) → row_index`
for O(1) location resolution.

**Changes:**

- In `View:render()`, after `self.display_rows` is built, construct:
  ```lua
  self._row_index = {
    by_location = {},     -- [file_id][side_line] = row_index
    by_file_header = {},  -- [file_id] = row_index
    by_file_range = {},   -- [file_id] = { first = idx, last = idx }
  }
  ```
- Rewrite `View:location_row()` to use `self._row_index.by_location` (O(1)).
- Rewrite `file_header_row()` to use `self._row_index.by_file_header`.
- Rewrite `display_row_for_source_index()` to build a hash from `(file_id, source_row_ref)`.
- Rewrite `target_anchor_row()` and `_file_row_range()` helpers.

**Impact:** `apply_syntax()` goes from O(rows × spans) to O(spans). On a 100-file diff
with 8,000 display rows and 20,000 syntax spans, ~10M comparisons saved per render.

**Files:** `lua/review-diff/init.lua`

### 1.2 Deferred syntax highlighting

**What:** Move `self:apply_syntax()` from inside `render()` to a `vim.schedule()` callback,
so diff content and line highlights appear immediately; syntax colors follow a frame later.

**Changes:**

```lua
function View:render()
  -- ... existing content, highlights, annotations, cursorline ...
  self:emit("rendered")
  vim.schedule(function()
    if not self.closed then
      self:apply_syntax()
    end
  end)
end
```

Must ensure `apply_syntax()` guards against `self.closed` since it runs deferred.

**Impact:** First-frame render time cut by 40-60% on large diffs with treesitter.

**Files:** `lua/review-diff/init.lua`

### 1.3 Display row text cache

**What:** Cache `render.text()` results keyed by `(row_hash, side, width)`. Invalidate on
window resize or refresh (new input data).

**Changes:**

- In `lua/review-diff/render.lua`, add a module-level cache:
  ```lua
  M._text_cache = {}
  ```
- `render.text()` checks cache before computing. Cache miss → compute and store.
- On `View:replace()` and window resize → clear cache.
- The cache key must include all properties that affect text output: `display_kind`,
  `file_id`, `source_row.old_line`, `source_row.new_line`, `source_row.old_text`,
  `source_row.new_text`, `collapsed`, `fold`, etc.

**Impact:** For operations that modify a single file, 95%+ of text lines are served from
cache instead of recomputed.

**Files:** `lua/review-diff/render.lua`

### 1.4 Skip unnecessary re-renders on hunk navigation

**What:** When `move_hunk()` targets a hunk that is already visible (file expanded, fold
expanded, target row in display_rows), just move the cursor without re-rendering.

**Changes:**

```lua
function View:move_hunk(direction)
  local targets = collect_hunk_targets(self)
  if #targets == 0 then return end
  local target = targets[next_hunk_target_index(self, targets, direction)]
  if not target then return end
  local row_index = display_row_for_source_index(self, target.file, target.source_index)
  if row_index then
    self:set_cursor_row(row_index)
    return  -- Target already visible, no re-render needed
  end
  self:expand_source_row(target.file, target.source_index)
  self:render()
  row_index = display_row_for_source_index(self, target.file, target.source_index)
  if row_index then
    self:set_cursor_row(row_index)
  end
end
```

**Impact:** No-op when navigating between visible hunks (common case).

**Files:** `lua/review-diff/init.lua`

### 1.5 Track diff buffers for efficient extmark cleanup

**What:** Instead of iterating `vim.api.nvim_list_bufs()` in `session.reset()`, track the
specific scratch buffers and clear only those.

**Changes:**

- In `lua/herdr-review/session.lua`, add `state.diff_buffers = {}` to the module state.
- On `on_view_opened()`, populate with `view.old_buf` and `view.new_buf`.
- In `reset()`, iterate only `state.diff_buffers`, checking `nvim_buf_is_valid` first.
- Clear `state.diff_buffers` on `reset()`.

**Files:** `lua/herdr-review/session.lua`

---

## Phase 2: Incremental Rendering

### 2.1 Row-level diff for file/fold toggle

**What:** When toggling a single file or fold, compute only the affected display rows,
replace only those lines in the buffer, and re-apply highlights only for that range.

**Changes:**

- Add `View:_file_row_range(file_id)` → `{ first = n, last = n }` returning the
  display_rows indices for that file (uses the row index from Phase 1.1).
- Add `View:_build_file_rows(file_id)` → `display_rows[]` returning the rows for one file,
  factoring in the current collapsed/expanded state.
- Rewrite `toggle_file_at_cursor()`:
  - Determine old row count and new row count for the toggled file.
  - Compute new row slice via `_build_file_rows`.
  - Replace the slice in `self.display_rows` and in both buffers via targeted
    `nvim_buf_set_lines`.
  - Re-apply highlights only for the inserted range.
  - Shift the row index entries for rows after the modified range.
- Rewrite `toggle_fold_at_cursor()` similarly.

**Impact:** Toggling a 200-line file in an 8,000-line diff goes from replacing 8,000
buffer lines to replacing 200.

**Files:** `lua/review-diff/init.lua`, `lua/review-diff/render.lua`

### 2.2 Per-file display row caching

**What:** Cache `model.visible_rows()` results on each file object and invalidate only
when state changes for that file.

**Changes:**

- In `model.visible_rows()`, store result on `file._visible_rows` and return it on
  subsequent calls with the same `context_lines`.
- Invalidate the cache in `build_file()` (new input data arrives).
- `display_rows()` assembles the full array from per-file cached slices.

**Files:** `lua/review-diff/model.lua`, `lua/review-diff/render.lua`

### 2.3 Syntax highlight partial invalidation

**What:** When only a few files change (expand/collapse), re-apply syntax highlights only
for those files' row ranges.

**Changes:**

- Extend `apply_syntax()` to accept an optional `changed_file_ids` table.
- Only clear and re-apply syntax extmarks for files in the set (or all if nil).
- The incremental render methods (2.1) pass the set of changed file IDs to `apply_syntax`.

**Files:** `lua/review-diff/init.lua`

---

## Phase 3: Async Model Building + Progressive Loading

### 3.1 Coroutine-based `vim.diff` batching

**What:** Process files in small batches (e.g., 3 per frame) using `vim.schedule()`,
yielding to the event loop between batches so the UI remains responsive.

**Changes:**

- Add `model.build_async(files, opts, on_file_callback, on_done_callback)`:
  - Processes files in batch_size batches.
  - Calls `on_file_callback(file, index, total)` after each file is processed.
  - Calls `on_done_callback(result)` after all files are complete.
  - Sorts files before calling `on_done`.
- Keep existing `model.build()` synchronous for non-progressive flows.
- Use a generation counter to cancel stale batches when `view:replace()` is called again.

**Files:** `lua/review-diff/model.lua`

### 3.2 Progressive viewer population

**What:** On initial load, show the viewer with file headers immediately, then stream
in content as each file's diff is computed.

**Changes:**

- `View:replace()` calls `model.build_async()` instead of `model.build()`.
- On `on_file_callback`: append the file to `self.files`, update a hint/status text,
  call `self:render()` (which will benefit from Phase 2 incremental rendering).
- On `on_done_callback`: clear hint text, sort files, final render, place cursor.
- The `"ready"` event fires immediately when the view tab opens (user can interact,
  close, etc. while files load).

**Files:** `lua/review-diff/init.lua`, `lua/herdr-review/init.lua`

### 3.3 File size threshold

**What:** Skip `vim.diff` for files exceeding a configurable size threshold. Show them
as a metadata row (same as binary files).

**Changes:**

- Add `max_file_size` to `DEFAULT_OPTIONS` (default: 1,000,000 bytes ≈ 1MB).
- In `model.build_file()`, check `old_text + new_text` length against threshold.
  If exceeded, set `file.too_large = true` and skip diff computation.
- The existing `display_rows()` already handles `too_large` files with a metadata row.

**Files:** `lua/review-diff/model.lua`, `lua/review-diff/init.lua`

### 3.4 Generation counter for stale batches

**What:** When the user refreshes while a progressive build is in progress, discard
stale callbacks to prevent stale data from overwriting the new build.

**Changes:**

- `View` gets a `_build_generation` counter, incremented on `replace()`.
- `build_async` callbacks check `self._build_generation == generation` before applying
  state. If mismatched, they return early (stale).

**Files:** `lua/review-diff/init.lua`, `lua/review-diff/model.lua`

---

## Files Affected

| File | Phase 1 | Phase 2 | Phase 3 |
|---|---|---|---|
| `lua/review-diff/init.lua` | 1.1, 1.2, 1.4 | 2.1, 2.3 | 3.2, 3.3, 3.4 |
| `lua/review-diff/render.lua` | 1.3 | 2.1, 2.2 | — |
| `lua/review-diff/model.lua` | — | 2.2 | 3.1, 3.3 |
| `lua/herdr-review/session.lua` | 1.5 | — | — |
| `lua/herdr-review/init.lua` | — | — | 3.2 |

## Testing

- Existing Plenary tests for storage, comments, paths, session, Diffview adaptation.
- Manual smoke test: `:ReviewDiff <large-ref>` — verify Loading indicator is brief,
  files appear progressively, toggling files/folds is responsive, hunk navigation is
  instant when no expansion is needed.
- Verify session load still applies comments and restores view state correctly after
  progressive loading.
- Verify `reset()` cleans up only the correct buffers.
- Verify stale generation counter prevents race conditions on rapid refresh.
- Test with `syntax.enabled = false` to verify syntax deferral doesn't error.
- Test `max_file_size` threshold with a deliberately large file.

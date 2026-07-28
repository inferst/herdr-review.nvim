# Hint Word Wrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the diff view hint line wrapped at `|` separator boundaries based on window width, so it fits on narrow windows.

**Architecture:** Add a `wrap_hint_text()` helper to `render.lua` that splits a hint string by `" | "` and groups segments into lines that fit within a given `strdisplaywidth`. In `View:render()` in `init.lua`, use this helper to create multiple hint display rows instead of one.

**Tech Stack:** Lua, Neovim 0.10+, strdisplaywidth

## Global Constraints

- Follow existing code style: 2-space indent, `local M = {}` pattern, LuaDoc annotations
- No behavior changes to non-hint display rows
- Hint must re-wrap on window resize (already handled by existing `render()` call on resize)

---

### Task 1: Add `wrap_hint_text()` to render.lua

**Files:**
- Modify: `lua/review-diff/render.lua` — add new function at end of module

**Interfaces:**
- Produces: `M.wrap_hint_text(hint_text: string, width: integer): string[]` — splits hint by `" | "`, groups segments into lines fitting `width` via `vim.fn.strdisplaywidth`

- [ ] **Step 1: Add `wrap_hint_text` function**

```lua
---@param hint_text string
---@param width integer
---@return string[]
function M.wrap_hint_text(hint_text, width)
  if not hint_text or hint_text == "" then
    return {}
  end
  local parts = vim.split(hint_text, " | ", { plain = true })
  if #parts == 0 then
    return {}
  end
  local prefix = parts[1] -- "Hint:"
  local segments = {}
  for i = 2, #parts do
    segments[#segments + 1] = parts[i]
  end
  local lines = {}
  local current = prefix
  for _, seg in ipairs(segments) do
    local candidate = current .. " | " .. seg
    if vim.fn.strdisplaywidth(candidate) <= width then
      current = candidate
    else
      lines[#lines + 1] = current
      current = "  " .. seg
    end
  end
  lines[#lines + 1] = current
  return lines
end
```

- [ ] **Step 2: Run lint**

```bash
make lint
```

- [ ] **Step 3: Commit**

```bash
git add lua/review-diff/render.lua
git commit -m "feat: add wrap_hint_text helper for hint line wrapping"
```

---

### Task 2: Use `wrap_hint_text()` in View:render()

**Files:**
- Modify: `lua/review-diff/init.lua:416-418` — replace single hint row with wrapped rows

**Interfaces:**
- Consumes: `render.wrap_hint_text(hint_text, width)` from Task 1
- Produces: multiple `{ display_kind = "hint", hint_text = line }` display rows

- [ ] **Step 1: Replace hint row insertion**

In `lua/review-diff/init.lua` at lines 416-418, replace:

```lua
  if self.hint_text then
    table.insert(self.display_rows, 1, { display_kind = "hint", hint_text = self.hint_text })
    table.insert(self.display_rows, 2, { display_kind = "hint", hint_text = "" })
  end
```

with:

```lua
  if self.hint_text then
    local width = vim.api.nvim_win_get_width(self.old_win)
    local hint_lines = render.wrap_hint_text(self.hint_text, width)
    for i = #hint_lines, 1, -1 do
      table.insert(self.display_rows, 1, { display_kind = "hint", hint_text = hint_lines[i] })
    end
    table.insert(self.display_rows, #hint_lines + 1, { display_kind = "hint", hint_text = "" })
  end
```

- [ ] **Step 2: Run lint**

```bash
make lint
```

- [ ] **Step 3: Run tests**

```bash
make test
```

- [ ] **Step 4: Commit**

```bash
git add lua/review-diff/init.lua
git commit -m "feat: wrap hint line at separator boundaries by window width"
```

---

### Task 3: Add unit test for wrap_hint_text

**Files:**
- Modify: `tests/review_diff_spec.lua` — add tests for `wrap_hint_text`

**Interfaces:**
- Consumes: `render.wrap_hint_text` from Task 1

- [ ] **Step 1: Add tests**

```lua
describe("wrap_hint_text", function()
  local render = require("review-diff.render")

  it("returns single line when fits width", function()
    local result = render.wrap_hint_text("Hint: ? help | cc comment", 100)
    assert.are.same({ "Hint: ? help | cc comment" }, result)
  end)

  it("wraps into multiple lines when exceeds width", function()
    local result = render.wrap_hint_text("Hint: ? help | cc comment | cd delete", 35)
    assert.are.same({ "Hint: ? help | cc comment", "  cd delete" }, result)
  end)

  it("wraps each segment individually when very narrow", function()
    local result = render.wrap_hint_text("Hint: ? help | cc comment | cd delete", 15)
    assert.are.same({ "Hint:", "  ? help", "  cc comment", "  cd delete" }, result)
  end)

  it("handles empty hint", function()
    local result = render.wrap_hint_text("", 80)
    assert.are.same({}, result)
  end)

  it("handles nil hint", function()
    local result = render.wrap_hint_text(nil, 80)
    assert.are.same({}, result)
  end)
end)
```

- [ ] **Step 2: Run tests**

```bash
make test
```
Expected: all 5 new tests pass

- [ ] **Step 3: Commit**

```bash
git add tests/review_diff_spec.lua
git commit -m "test: add unit tests for wrap_hint_text"
```

---

### Task 4: Manual smoke test in Neovim

- [ ] **Step 1: Open Diffview with the plugin active**

```vim
:DiffviewOpen
```

- [ ] **Step 2: Verify hint wraps on narrow window**

Resize the Neovim window to a narrow width (~50 columns). Verify the hint line splits into multiple lines at `|` boundaries.

- [ ] **Step 3: Verify hint is single line on wide window**

Maximize the window. Verify the hint renders as a single line.

- [ ] **Step 4: Verify resize re-wraps**

Resize the window while the diff view is open. Verify hint lines update correctly.

- [ ] **Step 5: Verify hint still respects `show_hint = false` config**

```lua
require("herdr-review").setup({ diff = { show_hint = false } })
```

Re-open Diffview. Verify no hint is shown.

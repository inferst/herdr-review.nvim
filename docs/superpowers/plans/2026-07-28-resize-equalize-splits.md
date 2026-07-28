# Resize: Equalise Diff Split Proportions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the old/new diff windows maintain 50/50 width split when the terminal is resized.

**Architecture:** Add a `VimResized` autocmd handler in `setup_autocmds` that calls `vim.cmd("wincmd =")` to re-balance windows, followed by `view:render()` to refresh content.

**Tech Stack:** Neovim Lua API (`VimResized` autocmd, `wincmd =`, `view:render()`)

**Spec:** `docs/superpowers/specs/2026-07-28-resize-equalize-splits-design.md`

## Global Constraints

- Add the new autocmd to the same augroup (`ReviewDiff{id}`) so it shares lifetime with the view.
- Guard with `not view.closed`, `not view.rendering`, and `vim.api.nvim_get_current_tabpage() == view.tabpage`.
- Place after the existing `WinResized` handler in `setup_autocmds`.

---

### Task 1: Add `VimResized` autocmd to `setup_autocmds`

**Files:**
- Modify: `lua/review-diff/init.lua:993-1001`

**Interfaces:**
- Consumes: existing `view` table (available as upvalue in `setup_autocmds`)
- Produces: `VimResized` handler registered in the view's augroup

- [ ] **Step 1: Read the target file to confirm the insertion point**

Read `lua/review-diff/init.lua` lines 988-1005 to see the exact code around the `WinResized` handler.

- [ ] **Step 2: Add the `VimResized` handler**

After the `WinResized` handler (after `end` on line 1000, before `end` on line 1001), insert:

```lua
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not view.closed and not view.rendering and vim.api.nvim_get_current_tabpage() == view.tabpage then
        vim.cmd("wincmd =")
        view:render()
      end
    end,
  })
```

- [ ] **Step 3: Run lint to verify syntax**

```bash
make lint
```

Expected: no errors.

- [ ] **Step 4: Run formatter**

```bash
make format
```

- [ ] **Step 5: Run tests**

```bash
make test PLENARY_PATH=deps/plenary.nvim
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lua/review-diff/init.lua docs/superpowers/plans/2026-07-28-resize-equalize-splits.md
git commit -m "fix: equalise diff split proportions on terminal resize"
```

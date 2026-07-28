# Resize: Equalise Diff Split Proportions

## Problem

When the terminal emulator window is resized the two diff panes (old / new) do
not maintain their 50/50 width split.  The existing `WinResized` handler in
`setup_autocmds` (`lua/review-diff/init.lua:993`) only calls `view:render()`,
which re-renders buffer content — it never re-balances the window layout.

## Solution

Add a second autocmd for the `VimResized` event (fires when the terminal window
changes size) alongside the existing `WinResized` handler.  On `VimResized`:

1. Check the view is still open, not currently rendering, and the user is on the
   diff tabpage.
2. Run `vim.cmd("wincmd =")` to equalise all windows on the tabpage (restores
   50/50).
3. Call `view:render()` so buffer content adapts to the new window widths.

`VimResized` is chosen over `WinResized` because it fires more reliably on
terminal resize across Neovim versions.

## Changes by file

### `lua/review-diff/init.lua` — `setup_autocmds`

```lua
vim.api.nvim_create_autocmd("VimResized", {
  group = group,
  callback = function()
    if not view.closed and not view.rendering
        and vim.api.nvim_get_current_tabpage() == view.tabpage then
      vim.cmd("wincmd =")
      view:render()
    end
  end,
})
```

Placed after the existing `WinResized` handler (line 1000), still inside
`setup_autocmds` and using the same augroup so it shares lifetime with the
view.

## Testing

Manual smoke test: open a diff (`:ReviewDiff`), resize the terminal window, and
verify the split returns to 50/50 and the content re-renders without visual
glitch.

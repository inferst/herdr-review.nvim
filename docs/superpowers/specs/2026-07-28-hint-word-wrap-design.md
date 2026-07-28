# Hint Word Wrap by Window Width

## Summary

The diff view hint line (showing keybindings) is currently rendered as a single
unwrapped line that overflows on narrow windows. Change it to wrap at `|`
separator boundaries based on window width.

## Current Behavior

- `lua/herdr-review/init.lua:95-112` builds `hint_text` as a single string:
  `"Hint: ? Show help | <Tab> Swap sides | cc Create comment | ..."`
- `lua/review-diff/init.lua:416-418` inserts one hint display row + one empty
  separator row into `display_rows`.
- `lua/review-diff/render.lua:180-181` returns the hint text as-is, ignoring
  the `width` parameter.

One display row = one buffer line, so the hint always occupies exactly one
buffer line regardless of window width.

## Desired Behavior

The hint wraps into multiple lines, splitting at `|` separator boundaries
when the combined width of segments exceeds the window width. Each wrapped
line becomes its own display row (and thus its own buffer line).

## Changes

### `lua/review-diff/init.lua` — `View:render()`

Instead of inserting a single hint display row:

```lua
table.insert(self.display_rows, 1, { display_kind = "hint", hint_text = self.hint_text })
```

Compute multiple hint rows:

1. Split `hint_text` by `" | "` into segments (first segment is `"Hint:"`, rest
   are `"? Show help"`, `"<Tab> Swap sides"`, etc.)
2. Use `vim.api.nvim_win_get_width(self.old_win)` (same width for both sides)
3. Accumulate segments into lines: start with current line prefix `"Hint:"`,
   then add `" | "` + next segment, measuring with `vim.fn.strdisplaywidth`.
   When adding the next segment would exceed window width, start a new line.
   New lines get `"  "` indent (two spaces) for visual alignment.
4. Insert each computed line as a `{ display_kind = "hint", hint_text = line }`
   row at the top of `display_rows`.
5. Keep the empty separator row after hint lines.

### `lua/review-diff/render.lua`

No changes needed. `text()` already returns `hint_text` as-is and
`highlight()` already applies `ReviewDiffHint` to all hint rows.

## Edge Cases

- **Window too narrow for any segment**: each segment gets its own line with
  `"  "` prefix. The minimum width for a segment is the segment itself.
- **Resize**: `render()` is called on each resize (triggered by autocmds), so
  hint lines re-wrap automatically.

# Hunk Navigation

## Problem

The review diff keymaps `]c` and `[c` are documented as changed-line
navigation, but the implementation is named `move_hunk`.  The current code in
`View:move_hunk()` scans only rendered `display_rows` and jumps to every changed
line.  This causes two issues:

1. Multi-line hunks require repeated `]c` / `[c` presses to leave the same hunk.
2. Changed rows inside collapsed files are absent from `display_rows`, so hunk
   navigation skips collapsed files entirely.

The desired behaviour is true hunk navigation: one jump per changed range, with
collapsed target files opened automatically.

## Design

Move the domain concept of a hunk into `review-diff.model`.  `model.build_file()`
will continue to build the aligned `file.rows` array, and will also attach a
`file.hunks` array.  Each hunk represents one contiguous changed range in
`file.rows`.

Example shape:

```lua
{
  id = 1,
  first_row = 12,
  last_row = 15,
  old_start = 20,
  old_end = 22,
  new_start = 20,
  new_end = 23,
}
```

`first_row` and `last_row` are indices into `file.rows`, not rendered display
rows.  They are therefore stable across collapsed files, collapsed context
folds, and re-renders.

The view keeps responsibility for UI behaviour:

- choosing the next or previous target;
- preserving wrap-around navigation;
- opening the target file if it is collapsed;
- expanding the context fold that contains the target row;
- re-rendering and placing the cursor on the target display row.

This keeps `review-diff.model` focused on diff structure and keeps Neovim
window/fold behaviour in `review-diff`'s `View`.

## Navigation behaviour

`View:move_hunk(direction)` will build its navigation targets from
`self.files[*].hunks` in the existing sorted file order.  Inside a file, targets
follow `file.hunks` order.  The target display row is the first changed row of
the hunk (`hunk.first_row`).

Expected behaviour:

- `]c` moves to the next hunk.
- `[c` moves to the previous hunk.
- Pressing `]c` on the last hunk wraps to the first hunk.
- Pressing `[c` on the first hunk wraps to the last hunk.
- Multi-line hunks are treated as one navigation target.
- If the target file is collapsed, only that file is expanded.
- If the target row is hidden inside a context fold, only that fold is expanded.
- The active side is preserved: old-side focus stays on old, new-side focus
  stays on new.
- Add-only or delete-only hunks still navigate to the aligned display row; the
  opposite side may be a placeholder with no source location.
- If there are no hunks, the command is a no-op.
- Binary and too-large files have no hunks and do not participate in hunk
  navigation.

## Changes by file

### `lua/review-diff/model.lua`

- Add `file.hunks` to the result of `M.build_file()`.
- Populate hunks from the diff indices already used to append changed rows.
- Store row ranges as source row indices in `file.rows`.
- Store side-specific source ranges for old and new sides.  For add-only hunks,
  `old_start` and `old_end` are `nil`.  For delete-only hunks, `new_start` and
  `new_end` are `nil`.

### `lua/review-diff/init.lua`

- Replace `View:move_hunk()`'s `display_rows` changed-line scan with hunk-target
  navigation based on `file.hunks`.
- Add a helper that opens a file and fold for a target `file.rows` index.
- Reuse the existing render and cursor placement mechanisms instead of
  introducing separate window state.

### `README.md`

- Update the review-tab keybinding description from "Next/previous changed
  line" to "Next/previous hunk".

## Testing

Add model tests:

- `build_file()` creates one hunk for a multi-line contiguous change.
- Separate changed ranges become separate hunks.
- Add-only hunks record `old_start = nil` and `old_end = nil`.
- Delete-only hunks record `new_start = nil` and `new_end = nil`.

Add view tests:

- `]c` skips from one hunk to the next hunk, not to the next changed line inside
  the same hunk.
- `[c` and `]c` preserve wrap-around behaviour.
- `]c` can target a hunk inside a collapsed file, expands that file, and leaves
  other files' collapsed state unchanged.
- Hunk navigation expands the context fold containing the target row when the
  target row is hidden by context folding.

Manual smoke test:

- Open a review with multiple files and multi-line hunks.
- Collapse at least one changed file.
- Use `[c` and `]c` from both old and new panes.
- Verify jumps are one per hunk, wrap around, and open only the target file.

## Out of scope

- Adding separate keymaps for changed-line navigation.
- Changing comment anchoring or storage.
- Changing file navigation (`[f` / `]f`).

# Diff Session State Restoration Design

## Problem

Running `:ReviewDiff`, changing the diff layout, opening a worktree file with
`<CR>`, and running `:ReviewDiff` again reuses the existing `review-diff.View`.
The asynchronous refresh calls `View:replace()`, which resets the cursor and
loses parts of the layout state. The current session snapshot is only captured
when the review tab is closed or when `R` is pressed, and it cannot identify a
diff-side cursor after focus has moved to the originating tab.

Related defects are part of the same change:

- `false` collapsed-file values are replaced by `collapse_on_open` because of
  an `or` fallback.
- Expanded context folds are neither captured nor restored.
- Cursor fallback paths use `new_path` even when the cursor is on the old side,
  which breaks renamed and deleted files.
- A pending snapshot can survive a different review and be applied later.

## Goals

- Preserve the diff UI state when the same review is refreshed or reopened from
  the originating tab.
- Preserve collapsed files, expanded context folds, cursor location, and diff
  side on a best-effort basis.
- Keep state restoration independent of comment persistence and re-anchoring.
- Prevent state from one `review_id` leaking into another review.
- Keep the standalone `review-diff` viewer consistent with the plugin facade.
- Cover the behavior with focused automated tests and manual Diffview-style
  smoke testing.

## Non-goals

- Persisting UI layout state to JSON or across Neovim restarts.
- Changing the review session storage schema or comment format.
- Changing the semantics of stale comments or comment re-anchoring.

## Design

### State ownership

`review-diff.View` owns transient display state. It exposes:

- `capture_state()` to return a deep-copied snapshot of the current view;
- `restore_state(state)` to apply a compatible snapshot without throwing on
  stale files or lines.

The snapshot contains:

```lua
{
  review_id = "stable-review-id",
  collapsed_files = { ["file-id"] = true|false },
  expanded_folds = { ["file-id:first:last"] = true },
  cursor = {
    file = "relative/path.lua",
    side = "old"|"new",
    line = 42,
  },
}
```

The viewer tracks the last active diff side internally. This allows
`capture_state()` to identify the cursor even when the current Neovim window
is the originating worktree window. Cursor paths are selected from the cursor
side: `old_path` for `old` and `new_path` for `new`.

### Replace behavior

`View:replace(input, opts)` accepts an optional captured state. If no state is
provided, it captures the current state at the start of the operation. After
building the new model, it restores the state only when the captured
`review_id` matches `input.review_id`. A different review keeps the configured
initial layout.

Restoration runs after `ready` callbacks. This preserves the existing session
loading flow: comments are loaded and their locations are expanded first, then
the user's layout and cursor are reapplied. A stale file or line does not abort
the replace; valid file layout state is kept and the cursor remains at the
initial or nearest valid row.

Collapsed-file values are copied using an explicit nil check, so a saved
`false` remains false. Expanded fold keys are copied as well; keys that do not
match the new model are harmless and do not render.

### Plugin lifecycle

For `R` and repeated `:ReviewDiff` commands, `herdr-review.init` captures the
state before starting the asynchronous Git resolve. The resolve callback passes
that snapshot to `View:replace(input, { state = saved_state })`, avoiding a
late capture after focus or content has changed.

`herdr-review.session` no longer implements layout parsing. It delegates state
capture and restore to the view and keeps only a pending snapshot for a fully
closed review tab. On the next view open it loads comments, applies a matching
pending snapshot, and clears the snapshot. A mismatched `review_id` discards
the pending state immediately.

The pending snapshot remains in memory only. Comment storage continues to use
the existing schema and files.

## Error handling

- Missing files, invalid side values, stale lines, and closed windows are
  ignored during restoration rather than raised as errors.
- A changed `review_id` skips restoration and clears incompatible pending
  state.
- Existing Git generation checks continue to prevent stale asynchronous
  results from replacing the active view.
- Existing storage errors continue to notify the user; they do not prevent
  valid view state from being restored.

## Testing

Add focused viewer tests for:

- preserving collapsed and expanded files through `replace()`;
- preserving expanded context folds;
- preserving cursor location and old/new side;
- capturing state while focus is outside the review tab;
- resetting state when `review_id` changes;
- retaining explicit `false` collapsed values;
- restoring renamed-file old-side paths correctly.

Add session tests for matching close/reopen restoration and mismatched pending
state disposal. Existing comment loading and re-anchoring tests must continue
to pass.

Verification consists of `make check` and a manual workflow covering:

1. `:ReviewDiff`, layout changes, `<CR>`, and repeated `:ReviewDiff`.
2. `R` refresh with files and context folds changed.
3. Closing and reopening the same review.
4. Opening a different review and confirming that the old layout is not
   carried over.

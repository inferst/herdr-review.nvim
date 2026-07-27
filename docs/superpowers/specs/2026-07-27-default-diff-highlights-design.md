# Default Diff Highlight Colors

## Problem

The diff viewer (`review-diff`) links its highlight groups to theme groups
(`DiffAdd`, `DiffDelete`, `DiffChange`, `DiffText`).  These theme groups often
look poor in the review-tab context: indistinguishable backgrounds, low contrast
with the tab's "empty" background, and no differentiation between line-level and
intra-line change highlighting.

## Solution

Add a single `highlights` config option that switches between two modes:

- `"default"` — built-in background colors (new default).
- `"theme"` — link to theme highlight groups (current behaviour).

When `"default"` is selected the plugin owns the colour values, so they are
consistent regardless of the active colourscheme.  Users who want to customise
can override any `ReviewDiff*` group with `:highlight` / `nvim_set_hl()`
directly — the README documents the full list of groups.

## Highlight groups

| Group | Role | Built-in colour |
|-------|------|-----------------|
| `ReviewDiffAdd` | added-line background | `bg=#2e3a2e` |
| `ReviewDiffDelete` | deleted-line background | `bg=#3a2e2e` |
| `ReviewDiffChange` | opposite-side context background | `bg=#2e2e3a` |
| `ReviewDiffAddIntra` | changed text inside an added line | `bg=#2a6a2a` |
| `ReviewDiffDeleteIntra` | changed text inside a deleted line | `bg=#6a2a2a` |

In `"theme"` mode `ReviewDiffText` is linked to `DiffText` as before.  In
`"default"` mode `ReviewDiffText` is **not** defined — the two intra-line groups
replace it.

## Changes by file

### `config.lua`

```diff
+ M.highlights = "default"
```

### `init.lua` (herdr-review)

Pass `opts.highlights` (defaulting to `"default"`) into `setup_options` so the
viewer receives it.

### `review-diff/init.lua`

- Extend `DEFAULT_OPTIONS` with `highlights = "default"`.
- `set_default_highlights()` checks `M.options.highlights`:
  - `"default"` → `nvim_set_hl` with concrete bg values and `default = true`.
  - `"theme"` → `nvim_set_hl` with `link = "Diff*"` and `default = true` (status
    quo).
- The inline-extmark block uses `inline.hl_group` instead of the hardcoded
  `"ReviewDiffText"`.

### `review-diff/render.lua`

`M.highlight()` returns an extra field in the inline range table:

```diff
  { start = …, finish = … }
+ { start = …, finish = …, hl_group = "ReviewDiffAddIntra" }
```

For old-side rows the inline group is `ReviewDiffDeleteIntra`; for new-side rows
it is `ReviewDiffAddIntra`.

### `README.md`

Add `highlights` to the config example.  Document the five `ReviewDiff*` groups
as override points.

## Migration

Users with `setup({})` get the new built-in colours automatically.  Anyone who
previously relied on the theme-linked appearance can opt out with:

```lua
highlights = "theme"
```

## Testing

- `render.highlight()` returns the correct inline hl group per side.
- `set_default_highlights()` creates concrete bg values in `"default"` mode and
  links in `"theme"` mode.
- Default value propagates from `herdr-review.setup()` through
  `viewer.setup()`.

## Objective
- Migrate `review-diff` from a public `View` object to a smaller `ReviewHandle` interface, preserving all existing behaviour while splitting internals into focused modules.

## Important Details
- All tests pass with `PLENARY_PATH=deps/plenary.nvim nvim --headless -u tests/minimal_init.lua -i NONE -n -c 'PlenaryBustedDirectory tests { minimal_init = "tests/minimal_init.lua" }'`
- Final verification: `make check PLENARY_PATH=deps/plenary.nvim`
- Lua uses two-space indentation, `snake_case` public functions, no new dependencies
- Internal `view.id` renamed to `view.uid` to avoid shadowing new `View:id()` method

## Work State
### Completed
- Task 1: Added handle read interface (id, metadata, status, context, cursor, anchor)
- Task 2: Added sync_annotations, migrated session comment placement
- Task 3: Added action methods, migrated herdr-review keymap registration
- Task 4: Migrated product callers to handle API (diff, comments, agent, hint)
- Task 5: Renamed open → open_resolved, documented public contract
- Task 6: Split into 6 focused modules (layout, state, annotations, actions, navigation, view)
- Task 7: Removed M.View export, moved rendering tests under `describe("review diff rendering internals")`, replaced `set_cursor_at_location` with `open_location`, replaced `view:set_annotations` with `sync_annotations`, replaced `view:resolve_location` with `resolve_anchor`, replaced `view.annotation_ns` with `annotations.get_namespace()`, replaced `view.tabpage`/`view.new_win`/`view.old_win` with public API calls

### Active
- Task 8: Final verification — make check ✅, public-contract usage acceptable ✅, file sizes reasonable (init.lua: 181 vs original 1382) ✅. **Manual smoke test** — needs user verification in Neovim.

### Blocked
- (none)

## Next Move
User to run manual smoke test in Neovim:
1. Open a repo with a worktree diff: `:ReviewDiff`
2. Verify: cc, cd, cl, cs, ]f, [f, ]c, [c, <Tab>, za, zR, zM, R, q

## Relevant Files
- `lua/review-diff/init.lua` — public facade (181 lines, down from ~1382)
- `lua/review-diff/view.lua` — View class (792 lines)
- `lua/review-diff/layout.lua`, `state.lua`, `annotations.lua`, `actions.lua`, `navigation.lua` — focused modules
- `tests/review_diff_view_spec.lua` — 25 tests, rendering internals scoped under nested describe

# Repository Guidelines

## Project Structure & Module Organization

This repository is a Neovim plugin written in Lua. The runtime source is in
`lua/herdr-review/`:

- `init.lua` registers setup, keymaps, and Diffview autocmds.
- `config.lua` contains defaults and shared constants.
- `diff.lua` integrates with Diffview and maps buffers to diff sides.
- `session.lua` manages review ranges and virtual-text extmarks.
- `storage.lua` persists comments as JSON.
- `ui.lua` implements comment input, the floating comment list, and agent handoff.
- `herdr.lua` wraps the `herdr` CLI.

`README.md` is the user-facing installation and usage documentation. There
are currently no checked-in tests, assets, or generated files.

## Build, Test, and Development Commands

There is no build system, package manifest, or automated test command. Install
the plugin locally through your Neovim plugin manager, then manually smoke-test
changes in a Neovim session with Diffview, plenary.nvim, and a running `herdr`
server:

```vim
:DiffviewOpen
<leader>rc
<leader>rl
<leader>rs
```

Check the working tree with `git status --short` before committing. If adding
tooling, document the command here and keep it reproducible from a clean
checkout.

## Coding Style & Naming Conventions

Use Lua with two-space indentation, local variables by default, and one module
table (`local M = {}`) returned from each file. Keep public module functions
named in `snake_case`; use descriptive local helper names. Preserve existing
LuaDoc annotations (`---@param`, `---@return`, and `---@class`) when changing
interfaces. Keep integration-specific logic in its existing module and avoid
introducing global state outside the established config/session tables.

## Testing Guidelines

No automated coverage requirement currently exists. For changes, exercise the
affected workflow manually in Diffview, including both old and new diff sides,
comment creation/edit/delete, session reloads, and agent submission when
relevant. Verify persisted JSON under Neovim's data directory when changing
storage behavior.

## Commit & Pull Request Guidelines

Use concise imperative commit subjects with a lowercase category prefix, for
example `fix: normalize diff paths` or `feat: add comment filtering`. Keep
commits focused. Pull requests should explain user-visible behavior, list
manual verification steps, link the relevant issue when one exists, and
include screenshots or recordings for floating-window or UI changes.

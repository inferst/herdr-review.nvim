# Repository Guidelines

## Project Structure & Module Organization

This repository is a Neovim plugin written in Lua. The runtime source is in
`lua/herdr-review/`:

- `init.lua` registers setup, keymaps, and Diffview autocmds.
- `config.lua` contains defaults and shared constants.
- `diff.lua` integrates with Diffview and maps buffers to diff sides.
- `comments.lua`, `paths.lua`, and `prompt.lua` contain pure review logic.
- `session.lua` manages review ranges and virtual-text extmarks.
- `storage.lua` persists comments as JSON.
- `ui.lua` is the public UI facade; `ui/` contains comment input, the floating
  comment list, and agent handoff implementations.
- `herdr.lua` wraps the `herdr` CLI.

`README.md` is the user-facing installation and usage documentation. There
are no generated files checked in.

## Build, Test, and Development Commands

The repository uses Make, Plenary, StyLua, and Luacheck. Install the test
dependency into the checkout and run the checks from a clean checkout:

```sh
git clone --depth 1 https://github.com/nvim-lua/plenary.nvim.git deps/plenary.nvim
make check PLENARY_PATH=deps/plenary.nvim
```

Individual commands are `make test`, `make lint`, `make format`, and
`make format-check`. Install the plugin locally through your Neovim plugin
manager, then manually smoke-test changes in a Neovim session with Diffview,
plenary.nvim, and a running `herdr` server:

```vim
:DiffviewOpen
cc
cl
cs
```

Check the working tree with `git status --short` before committing. CI runs
tests on Neovim 0.10 and the latest stable release.

## Coding Style & Naming Conventions

Use Lua with two-space indentation, local variables by default, and one module
table (`local M = {}`) returned from each file. Keep public module functions
named in `snake_case`; use descriptive local helper names. Preserve existing
LuaDoc annotations (`---@param`, `---@return`, and `---@class`) when changing
interfaces. Keep integration-specific logic in its existing module and avoid
introducing global state outside the established config/session tables.

## Testing Guidelines

Tests use Plenary and focus on storage, comment rules, path handling, prompt
generation, Diffview adaptation, and session extmarks. For changes, also
exercise the affected workflow manually in Diffview, including both old and
new diff sides, comment creation/edit/delete, session reloads, and agent
submission when relevant. Verify persisted JSON under Neovim's data directory
when changing storage behavior.

## Commit & Pull Request Guidelines

Use concise imperative commit subjects with a lowercase category prefix, for
example `fix: normalize diff paths` or `feat: add comment filtering`. Keep
commits focused. Pull requests should explain user-visible behavior, list
manual verification steps, link the relevant issue when one exists, and
include screenshots or recordings for floating-window or UI changes.

## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues. See
`docs/agents/issue-tracker.md`.

### Triage labels

Use the standard triage label vocabulary. See
`docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository. See `docs/agents/domain.md`.

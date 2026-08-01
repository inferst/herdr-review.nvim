# herdr-review.nvim

Code review UI for Neovim with Git and [herdr](https://github.com/herdr/herdr) integration.

https://github.com/user-attachments/assets/da92b09d-4720-44bd-bc56-01f9cbd11113

## Features

- Compare branches, commits, or uncommitted changes
- Show modified, added, deleted, renamed files with line-level and intra-line diff highlighting
- Leave, edit, and delete comments
- Send comments to a herdr agent for review handoff

## Requirements

- Neovim 0.10+
- Git
- [herdr](https://github.com/herdr/herdr) CLI installed and running for agent handoff
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)

Tree-sitter parsers are optional. If a parser is unavailable for a file, the
review remains usable without syntax highlighting.

## Installation

```lua
-- lazy.nvim
{
  "inferst/herdr-review.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("herdr-review").setup()
  end,
}
```

## Usage

Run `:ReviewDiff` from the repository's `cwd`.

```vim
:ReviewDiff                  " HEAD versus the worktree
:ReviewDiff main             " main versus the worktree
:ReviewDiff abc123           " commit versus the worktree
:ReviewDiff origin/main..HEAD
:ReviewDiff main...HEAD      " merge-base(main, HEAD) versus HEAD
:ReviewDiff main...WORKTREE  " merge-base(main, HEAD) versus worktree
```

Remote refs are resolved locally. The command does not fetch automatically.

### Review-tab keybindings

| Key | Action |
|-----|--------|
| `<Tab>` | Collapse/expand the file group under the cursor |
| `<CR>` | Open the worktree file in the originating tab/window |
| `]f` / `[f` | Next/previous file |
| `]c` / `[c` | Next/previous hunk |
| `za` | Toggle a context fold |
| `zR` / `zM` | Expand/collapse everything |
| `R` | Refresh the Git snapshot |
| `?` | Show review keymaps |
| `q` | Close the review tab |

Left-side and historical right-side `<CR>` targets are intentionally not opened in an ordinary buffer. Comment-list jumps can focus either side inside the review tab.

### Comment keybindings

| Key | Action |
|-----|--------|
| `cc` | Add or edit a comment on the current source line |
| `cd` | Delete a comment on the current source line |
| `cl` | Open the comment list |
| `cs` | Send non-stale comments to a herdr agent |

Comment-list keybindings remain `<CR>` to jump, `e` to edit, `d` to delete, and `q`/`<Esc>` to close.

## Configuration

```lua
require("herdr-review").setup({
  highlights = "default",  -- "default" or "theme"; "theme" links to DiffAdd etc.
  diff = {
    context_lines = 3,
    ignore_whitespace = false,
    collapse_on_open = true,
    sticky_file_header = true, -- set false to disable the sticky file header
    intra_line = true,
    max_file_bytes = 2 * 1024 * 1024,
    max_file_lines = 100000,
  },
  keymaps = {
    create_comment = "cc",
    delete_comment = "cd",
    open_list = "cl",
    send_to_agent = "cs",
  },
})
```

### Highlight overrides

When `highlights = "default"` the viewer uses built-in colours.  You can
override any group with `:highlight` or `vim.api.nvim_set_hl()`:

| Group | Default |
|-------|---------|
| `ReviewDiffAdd` | `bg=#2e3a2e` |
| `ReviewDiffDelete` | `bg=#3a2e2e` |
| `ReviewDiffChange` | `bg=#2e2e3a` |
| `ReviewDiffAddIntra` | `bg=#2a6a2a` — changed text inside added lines |
| `ReviewDiffDeleteIntra` | `bg=#6a2a2a` — changed text inside deleted lines |

Example:

```lua
vim.api.nvim_set_hl(0, "ReviewDiffAdd", { bg = "#1e3a1e", fg = "#ffffff" })
```

## Viewer interface

The standalone viewer lives under the `review-diff` namespace and accepts a resolved diff model independent of Git:

```lua
local review = require("review-diff").open({
  repo_root = "/project",
  review_id = "stable-id",
  spec = spec,
  files = resolved_files,
})

review:sync_annotations({
  {
    id = "comment-1",
    anchor = {
      file = "lua/init.lua",
      side = "right",
      line = 12,
      context = "nearby\nsource\nlines",
    },
    text = "Review this line",
  },
})

review:open_location({ file = "lua/init.lua", side = "right", line = 12 })
```

The viewer exposes review identity, metadata, source locations, source context, anchor resolution, lifecycle events, annotations, and action registration. It owns no comment persistence or herdr-specific behaviour. Buffers, windows, display rows, extmarks, fold keys, and state snapshots are implementation details.

## Storage

Comments are stored under `stdpath("data") .. "/herdr-review/sessions"` using schema version 4. The session key includes the repository root and resolved Git object IDs.

## Development

Install the test dependency into the checkout and run the checks:

```sh
git clone --depth 1 https://github.com/nvim-lua/plenary.nvim.git deps/plenary.nvim
make check PLENARY_PATH=deps/plenary.nvim
```

Available commands:

| Command | Action |
|---------|--------|
| `make test` | Run headless Plenary tests |
| `make lint` | Run Luacheck |
| `make format` | Format Lua files with StyLua |
| `make format-check` | Check StyLua formatting |
| `make check` | Run formatting, lint, and tests |

## License

MIT

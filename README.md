# herdr-review.nvim

Code review UI for Neovim with Git and [herdr](https://github.com/herdr/herdr) integration.

The plugin opens a dedicated review tab with two read-only columns: the old file on the left and the new file on the right. It does not depend on Diffview.nvim.

https://github.com/user-attachments/assets/da92b09d-4720-44bd-bc56-01f9cbd11113

## Features

- Compare uncommitted changes, branches, commits, remote-tracking branches, or explicit Git ranges
- Include staged, unstaged, and untracked files in worktree reviews
- Show modified, added, deleted, renamed, binary, and oversized files
- Group changes by file and collapse groups with `<Tab>`
- Align old/new lines with git-like line-level highlighting by default, with optional intra-line highlighting
- Highlight source text with Tree-sitter when a language parser is available
- Leave comments on any real old/new source line
- Persist comments by repository and resolved Git object IDs
- Re-anchor comments from their saved context when lines move
- Review comments in a floating list and send fresh comments to a herdr agent

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
  "inferst/nvim-herdr-review",
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
| `<CR>` | Open the new worktree file in the originating tab/window |
| `]f` / `[f` | Next/previous file |
| `]c` / `[c` | Next/previous changed line |
| `za` | Toggle a context fold |
| `zR` / `zM` | Expand/collapse everything |
| `R` | Refresh the Git snapshot |
| `?` | Show review keymaps |
| `q` | Close the review tab |

Old-side and historical new-side `<CR>` targets are intentionally not opened in an ordinary buffer. Comment-list jumps can focus either side inside the review tab.

### Comment keybindings

| Key | Action |
|-----|--------|
| `<leader>rc` | Add or edit a comment on the current source line |
| `<leader>rl` | Open the comment list |
| `<leader>rs` | Send non-stale comments to a herdr agent |

Comment-list keybindings remain `<CR>` to jump, `e` to edit, `d` to delete, and `q`/`<Esc>` to close.

## Configuration

```lua
require("herdr-review").setup({
  diff = {
    context_lines = 3,
    ignore_whitespace = false,
    intra_line = false,
    line_numbers = true,
    syntax = {
      enabled = true,
      engine = "treesitter",
    },
    max_file_bytes = 2 * 1024 * 1024,
    max_file_lines = 100000,
  },
  keymaps = {
    create_comment = "rc",
    open_list = "rl",
    send_to_agent = "rs",
  },
})
```

Review buffers are unlisted, read-only scratch buffers. The review tab is reused when `:ReviewDiff` is invoked again.

## Viewer interface

The standalone viewer lives under the `review-diff` namespace and can be used with a resolved model independent of Git:

```lua
local view = require("review-diff").open({
  repo_root = "/project",
  review_id = "stable-id",
  spec = spec,
  files = resolved_files,
})

view:set_annotations({
  {
    id = "comment-1",
    location = { file = "lua/init.lua", side = "new", line = 12 },
    text = "Review this line",
  },
})

view:open_location({ file = "lua/init.lua", side = "new", line = 12 })
```

The viewer exposes source locations, source context, file metadata, review identity, lifecycle events, annotations, and keymap registration. It owns no comment persistence or herdr-specific behavior.

## Storage

Comments are stored under `stdpath("data") .. "/herdr-review/sessions"` using schema version 3. The session key includes the repository root and resolved Git object IDs. Existing Diffview-era sessions are left untouched and are not migrated.

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

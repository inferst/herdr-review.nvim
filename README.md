# nvim-herdr-review

Code review plugin for Neovim with [Diffview.nvim](https://github.com/sindrets/diffview.nvim) and [herdr](https://github.com/herdr/herdr) integration.

Leave comments on diff lines, review them in a floating window, and send to a herdr agent for fixing.

## Features

- Comment on any line in Diffview (old or new side)
- Virtual text shows comments inline in the diff buffer
- Floating window with full comment list, navigation, and CRUD
- Send all comments to a herdr agent in one batch
- Comments persist between sessions (loaded by commit range)

## Requirements

- [Diffview.nvim](https://github.com/sindrets/diffview.nvim)
- [herdr](https://github.com/herdr/herdr) CLI installed and running
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)

## Installation

```lua
-- lazy.nvim
{
  "inferst/nvim-herdr-review",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "sindrets/diffview.nvim",
  },
  config = function()
    require("herdr-review").setup()
  end,
}
```

## Usage

1. Open Diffview: `:DiffviewOpen`
2. Navigate to a line and press `<leader>gc` to add a comment
3. Press `<leader>gl` to open the comment list
4. Press `<leader>gs` to send comments to a herdr agent

## Keybindings

| Key | Action |
|-----|--------|
| `<leader>gc` | Add comment on current diff line |
| `<leader>gl` | Open comment list (floating window) |
| `<leader>gs` | Send comments to herdr agent |

### Comment list keybindings

| Key | Action |
|-----|--------|
| `<CR>` | Jump to comment location |
| `e` | Edit comment |
| `d` | Delete comment |
| `q` | Close window |

## Configuration

```lua
require("herdr-review").setup({
  keymaps = {
    create_comment = "gc",
    open_list = "gl",
    send_to_agent = "gs",
  },
})
```

## How it works

- Comments are stored in `~/.local/share/nvim/herdr-review/<commit-range>.json`
- Each comment is tied to a file, side (old/new), and line number
- On `<leader>gs`, a structured prompt is sent to the selected herdr agent
- Comments are marked as "sent" after successful delivery

## License

MIT

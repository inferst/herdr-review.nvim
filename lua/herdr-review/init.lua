local config = require("herdr-review.config")
local ui = require("herdr-review.ui")
local session = require("herdr-review.session")
local diff = require("herdr-review.diff")

local M = {}

function M.setup(opts)
  opts = opts or {}

  if opts.keymaps then
    for k, v in pairs(opts.keymaps) do
      config.keymaps[k] = v
    end
  end

  local group = vim.api.nvim_create_augroup("HerdrReview", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    pattern = "DiffviewViewOpened",
    group = group,
    callback = function()
      session.on_view_opened()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "DiffviewDiffBufWinEnter",
    group = group,
    callback = function(args)
      local bufnr = args.buf
      local ok, view = pcall(function()
        return require("diffview.lib").get_current_view()
      end)

      if not ok or not view or not view.cur_layout then
        return
      end

      local cur_win = vim.api.nvim_get_current_win()
      local layout = view.cur_layout

      local side = nil
      local file = nil

      if layout.a and layout.a.id == cur_win then
        side = "old"
        file = layout.a.file
      elseif layout.b and layout.b.id == cur_win then
        side = "new"
        file = layout.b.file
      end

      if side and file then
        diff.set_buf_side(bufnr, side, file)
      end

      session.on_buf_enter(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function()
      session.on_buf_enter(vim.api.nvim_get_current_buf())
    end,
  })

  vim.keymap.set("n", "<leader>" .. config.keymaps.create_comment, function()
    ui.create_comment()
  end, { desc = "Herdr Review: Add comment" })

  vim.keymap.set("n", "<leader>" .. config.keymaps.open_list, function()
    ui.open_list()
  end, { desc = "Herdr Review: Open comment list" })

  vim.keymap.set("n", "<leader>" .. config.keymaps.send_to_agent, function()
    ui.send_to_agent()
  end, { desc = "Herdr Review: Send to agent" })
end

return M

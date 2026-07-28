local M = {}

M.ns = vim.api.nvim_create_namespace("herdr-review")

M.data_dir = vim.fn.stdpath("data") .. "/herdr-review"

M.list_width = 80

M.keymaps = {
  create_comment = "cc",
  open_list = "cl",
  send_to_agent = "cs",
}

M.highlights = "default"

M.diff = {
  collapse_on_open = true,
  line_numbers = true,
  show_hint = true,
}

return M

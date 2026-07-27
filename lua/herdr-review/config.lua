local M = {}

M.ns = vim.api.nvim_create_namespace("herdr-review")

M.data_dir = vim.fn.stdpath("data") .. "/herdr-review"

M.list_width = 80

M.keymaps = {
  create_comment = "rc",
  open_list = "rl",
  send_to_agent = "rs",
}

M.highlights = "default"

M.diff = {
  collapse_on_open = true,
  line_numbers = true,
}

return M

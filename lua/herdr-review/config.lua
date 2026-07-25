local M = {}

M.ns = vim.api.nvim_create_namespace("herdr-review")

M.data_dir = vim.fn.stdpath("data") .. "/herdr-review"

M.keymaps = {
  create_comment = "gc",
  open_list = "gl",
  send_to_agent = "gs",
}

return M

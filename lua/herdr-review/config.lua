local M = {}

M.data_dir = vim.fn.stdpath("data") .. "/herdr-review"

M.list_width = 80

M.keymaps = {
  create_comment = "cc",
  delete_comment = "cd",
  open_list = "cl",
  send_to_agent = "cs",
}

M.highlights = "default"

M.diff = {
  collapse_on_open = true,
  show_hint = true,
  sticky_file_header = true,
}

return M

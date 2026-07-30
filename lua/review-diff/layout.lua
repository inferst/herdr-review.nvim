local M = {}

function M.valid_tabpage(tabpage)
  return tabpage and vim.api.nvim_tabpage_is_valid(tabpage)
end

function M.valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function M.create_scratch(name)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  return bufnr
end

function M.set_window_options(win)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
end

function M.open_tab(view)
  vim.cmd("tabnew")
  view.tabpage = vim.api.nvim_get_current_tabpage()
  local placeholder = vim.api.nvim_get_current_buf()
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, view.old_buf)
  vim.cmd("rightbelow vsplit")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, view.new_buf)
  view.old_win = left_win
  view.new_win = right_win
  view.win_sides[left_win] = "old"
  view.win_sides[right_win] = "new"
  M.set_window_options(left_win)
  M.set_window_options(right_win)
  if vim.api.nvim_buf_is_valid(placeholder) and placeholder ~= view.old_buf and placeholder ~= view.new_buf then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end
end

return M

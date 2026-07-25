local M = {}

---@class BufSideMap
---@field side string "old"|"new"
---@field file table

local buf_side_map = {}

---@param bufnr integer
---@param side string
---@param file table
function M.set_buf_side(bufnr, side, file)
  buf_side_map[bufnr] = { side = side, file = file }
end

---@param bufnr integer
---@return string|nil, table|nil
function M.get_buf_side(bufnr)
  local entry = buf_side_map[bufnr]
  if entry then
    return entry.side, entry.file
  end
  return nil, nil
end

---@param bufnr integer
function M.clear_buf_side(bufnr)
  buf_side_map[bufnr] = nil
end

---@return table|nil
function M.get_current_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  return lib.get_current_view()
end

---@return string|nil file, string|nil side, integer|nil line
function M.get_cursor_context()
  local view = M.get_current_view()
  if not view or not view.cur_entry then
    return nil, nil, nil
  end

  local cur_win = vim.api.nvim_get_current_win()
  local layout = view.cur_layout

  local side = nil
  if layout.a and layout.a.id == cur_win then
    side = "old"
  elseif layout.b and layout.b.id == cur_win then
    side = "new"
  end

  local win = (side == "old") and layout.a or layout.b
  if not win or not win.id then
    return nil, nil, nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win.id)
  local line = cursor[1]

  local entry = view.cur_entry
  local file = entry.path
  local file_old = entry.oldpath

  return file, side, line, file_old
end

---@return table[]
function M.get_diff_lines(bufnr)
  local hunks = {}
  local prev_start = nil
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for line = 1, line_count do
    local diff_hl = vim.fn.diff_hlID(line, 0)
    if diff_hl ~= 0 then
      if not prev_start then
        prev_start = line
      end
    else
      if prev_start then
        table.insert(hunks, { first = prev_start, last = line - 1 })
        prev_start = nil
      end
    end
  end

  if prev_start then
    table.insert(hunks, { first = prev_start, last = line_count })
  end

  return hunks
end

---@param bufnr integer
---@return string[]
function M.get_context(bufnr, line, count)
  count = count or 3
  local lines = vim.api.nvim_buf_get_lines(bufnr, line - count, line + count, false)
  return lines
end

return M

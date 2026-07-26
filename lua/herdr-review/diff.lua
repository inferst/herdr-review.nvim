local M = {}

---@class DiffBufferContext
---@field side "old"|"new"
---@field file table|string|nil
---@field path string|nil

local buf_contexts = {}

---@param file table|string|nil
---@return string|nil
local function file_path(file)
  if type(file) == "string" then
    return file
  end
  return file and file.path or nil
end

---@param entry table|nil
---@param file table|string|nil
---@param side "old"|"new"
---@return string|nil
local function side_path(entry, file, side)
  if entry then
    if side == "old" then
      return entry.oldpath or entry.path
    end
    return entry.path or entry.oldpath
  end

  return file_path(file)
end

---@param bufnr integer
---@param side "old"|"new"
---@param file table|string|nil
---@param path string|nil
function M.set_buf_side(bufnr, side, file, path)
  buf_contexts[bufnr] = { side = side, file = file, path = path }
end

---@param bufnr integer
---@return "old"|"new"|nil, table|string|nil
function M.get_buf_side(bufnr)
  local context = buf_contexts[bufnr]
  if not context then
    return nil, nil
  end
  return context.side, context.file
end

---@param bufnr integer
---@return string|nil
function M.get_buf_path(bufnr)
  local context = buf_contexts[bufnr]
  return context and context.path or nil
end

---@return table|nil
function M.get_current_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  return lib.get_current_view()
end

---@return DiffBufferContext|nil
function M.get_current_buffer_context()
  local view = M.get_current_view()
  if not view or not view.cur_layout then
    return nil
  end

  local cur_win = vim.api.nvim_get_current_win()
  local layout = view.cur_layout
  local side
  local file

  if layout.a and layout.a.id == cur_win then
    side = "old"
    file = layout.a.file
  elseif layout.b and layout.b.id == cur_win then
    side = "new"
    file = layout.b.file
  end

  if not side then
    return nil
  end

  return {
    side = side,
    file = file,
    path = side_path(view.cur_entry, file, side),
  }
end

---@param bufnr integer
---@return DiffBufferContext|nil
function M.capture_buffer_context(bufnr)
  local context = M.get_current_buffer_context()
  if not context then
    return nil
  end

  M.set_buf_side(bufnr, context.side, context.file, context.path)
  return context
end

---@return string|nil file, "old"|"new"|nil side, integer|nil line
function M.get_cursor_context()
  local view = M.get_current_view()
  if not view or not view.cur_entry or not view.cur_layout then
    return nil, nil, nil
  end

  local context = M.get_current_buffer_context()
  if not context then
    return nil, nil, nil
  end

  local win = context.side == "old" and view.cur_layout.a or view.cur_layout.b
  if not win or not win.id then
    return nil, nil, nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win.id)
  return context.path, context.side, cursor[1]
end

---@param bufnr integer
---@param line integer
---@param count integer|nil
---@return string[]
function M.get_context(bufnr, line, count)
  count = count or 3
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start = math.max(0, line - count - 1)
  local finish = math.min(line_count, line + count)
  return vim.api.nvim_buf_get_lines(bufnr, start, finish, false)
end

return M

local viewer = require("review-diff")

local M = {}

local buf_contexts = {}

---@param bufnr integer
---@param side "old"|"new"
---@param file string|nil
function M.set_buf_context(bufnr, side, file)
  buf_contexts[bufnr] = { side = side, file = file }
end

---@param bufnr integer
---@return "old"|"new"|nil, string|nil
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
  return context and context.file or nil
end

---@return table|nil
function M.get_current_view()
  return viewer.current()
end

---@return table|nil
function M.get_current_buffer_context()
  local view = viewer.current()
  if not view then
    return nil
  end
  local location = view:get_cursor_location()
  if not location then
    return nil
  end
  return {
    side = location.side,
    file = { path = location.file },
    path = location.file,
  }
end

---@param bufnr integer
---@return table|nil
function M.capture_buffer_context(bufnr)
  local view = viewer.current()
  if not view then
    return nil
  end
  local context = view:buffer_context(bufnr)
  if not context then
    return nil
  end
  M.set_buf_context(bufnr, context.side, context.path)
  return context
end

---@return string|nil file, "old"|"new"|nil side, integer|nil line
function M.get_cursor_context()
  local view = viewer.current()
  if not view then
    return nil, nil, nil
  end
  local location = view:get_cursor_location()
  if not location then
    return nil, nil, nil
  end
  return location.file, location.side, location.line
end

---@param bufnr integer
---@param line integer
---@param count integer|nil
---@return string[]
function M.get_context(bufnr, line, count)
  local view = viewer.current()
  local side, file = M.get_buf_side(bufnr)
  if not view or not side or not file then
    return {}
  end
  local context = view:get_context({ file = file, side = side, line = line }, count)
  return context or {}
end

return M

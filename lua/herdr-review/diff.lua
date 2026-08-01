local viewer = require("review-diff")

local M = {}

---@return table|nil
function M.get_current_view()
  return viewer.current()
end

---@return string|nil file, "left"|"right"|nil side, integer|nil line
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

return M

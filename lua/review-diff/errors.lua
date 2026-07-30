local M = {}

---Builds a structured error result shared across the viewer's public surface.
---@param code string
---@param message string
---@return { code: string, message: string }
function M.result(code, message)
  return { code = code, message = message }
end

return M

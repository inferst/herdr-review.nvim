local M = {}

---@param path string|nil
---@return string|nil
function M.normalize(path)
  if not path then
    return nil
  end

  while path:sub(1, 2) == "./" do
    path = path:sub(3)
  end
  return path
end

---@param left string|nil
---@param right string|nil
---@return boolean
function M.equal(left, right)
  return M.normalize(left) == M.normalize(right)
end

return M

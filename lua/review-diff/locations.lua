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
  return path:gsub("\\", "/")
end

---@param file table
---@param side "old"|"new"
---@return string|nil
function M.path(file, side)
  if side == "old" then
    return file.old_path
  end
  return file.new_path
end

---@param files table[]
---@param location table|nil
---@return table|nil
function M.file_for(files, location)
  if not location or not location.file or not location.side then
    return nil
  end

  for _, file in ipairs(files) do
    if M.normalize(M.path(file, location.side)) == M.normalize(location.file) then
      return file
    end
  end
  return nil
end

return M

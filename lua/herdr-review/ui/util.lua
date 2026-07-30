local storage = require("herdr-review.storage")

local M = {}

---@param err string|nil
function M.notify_storage_error(err)
  vim.notify(err or "Could not access review session", vim.log.levels.ERROR)
end

---Loads stored comments for a range, reporting storage errors to the user.
---@param range string
---@return ReviewComment[]|nil
function M.load_comments(range)
  local stored, err = storage.get_comments(range)
  if not stored then
    M.notify_storage_error(err)
    return nil
  end
  return stored
end

return M

local M = {}

---@class ReviewComment
---@field id string
---@field file string
---@field side "left"|"right"
---@field line integer
---@field text string
---@field context string|nil
---@field context_start integer|nil
---@field created_at string

---@param comment ReviewComment
---@param other ReviewComment
---@return boolean
local function comes_before(comment, other)
  if comment.file ~= other.file then
    return comment.file < other.file
  end

  local comment_side = comment.side == "left" and 1 or 2
  local other_side = other.side == "left" and 1 or 2
  if comment_side ~= other_side then
    return comment_side < other_side
  end

  if comment.line ~= other.line then
    return comment.line < other.line
  end

  return comment.id < other.id
end

---@param comments ReviewComment[]
---@return ReviewComment[]
function M.sort(comments)
  local sorted = {}
  for _, comment in ipairs(comments) do
    table.insert(sorted, comment)
  end
  table.sort(sorted, comes_before)
  return sorted
end

---@param comments ReviewComment[]
---@param file string
---@param side "left"|"right"
---@param line integer
---@return ReviewComment|nil
function M.find_at(comments, file, side, line)
  for _, comment in ipairs(comments) do
    if comment.file == file and comment.side == side and comment.line == line then
      return comment
    end
  end
  return nil
end

return M

local M = {}

---@param range string
---@param comments ReviewComment[]
---@return string
function M.build(range, comments)
  local lines = {
    "You are reviewing code. Here are the review comments for this diff.",
    "",
    "Diff range: " .. range,
    "",
  }

  for _, comment in ipairs(comments) do
    table.insert(lines, "---")
    table.insert(lines, string.format("File: %s (%s, line %s)", comment.file, comment.side, comment.line))
    table.insert(lines, "Comment: " .. comment.text)
  end

  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, "Please fix all issues mentioned above.")

  return table.concat(lines, "\n")
end

return M

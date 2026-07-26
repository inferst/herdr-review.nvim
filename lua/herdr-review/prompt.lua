local M = {}

---@param lines string[]
---@param comment ReviewComment
local function append_context(lines, comment)
  if not comment.context or comment.context == "" then
    return
  end

  local marker = comment.side == "old" and "-" or "+"
  for context_line in (comment.context .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, marker .. context_line)
  end
end

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

  for index, comment in ipairs(comments) do
    if index > 1 then
      table.insert(lines, "")
    end

    local suffix = comment.side == "old" and " (removed)" or ""
    table.insert(lines, string.format("%s:%s%s", comment.file, comment.line, suffix))
    append_context(lines, comment)
    table.insert(lines, comment.text)
  end

  table.insert(lines, "")
  table.insert(lines, "Please fix all issues mentioned above.")

  return table.concat(lines, "\n")
end

return M

local M = {}

local CONTEXT_RADIUS = 3

---@param comment ReviewComment
---@return string|nil
local function get_context_line(comment)
  if not comment.context or comment.context == "" then
    return nil
  end

  local context_lines = {}
  for context_line in (comment.context .. "\n"):gmatch("(.-)\n") do
    table.insert(context_lines, context_line)
  end

  if #context_lines == 1 then
    return context_lines[1]
  end

  local context_start = comment.context_start or math.max(1, comment.line - CONTEXT_RADIUS)
  local context_index = comment.line - context_start + 1
  return context_lines[context_index]
end

---@param lines string[]
---@param comment ReviewComment
local function append_context(lines, comment)
  local context_line = get_context_line(comment)
  if not context_line then
    return
  end

  local marker = comment.side == "old" and "-" or "+"
  table.insert(lines, marker .. context_line)
end

---@param _range string
---@param comments ReviewComment[]
---@return string
function M.build(_range, comments)
  local lines = {}

  for index, comment in ipairs(comments) do
    if index > 1 then
      table.insert(lines, "")
    end

    local suffix = comment.side == "old" and " (removed)" or ""
    table.insert(lines, string.format("%s:%s%s", comment.file, comment.line, suffix))
    append_context(lines, comment)
    table.insert(lines, comment.text)
  end

  return table.concat(lines, "\n")
end

return M

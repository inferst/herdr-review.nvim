local locations = require("review-diff.locations")
local errors = require("review-diff.errors")

local M = {}

---Returns the source lines surrounding a location within +/- radius.
---@param files table[]
---@param location table
---@param radius integer
---@return string[]|nil lines, string|nil error
function M.get_context(files, location, radius)
  local file = locations.file_for(files, location)
  if not file then
    return nil, "file not found"
  end
  local lines = location.side == "old" and file.old_lines or file.new_lines
  if not location.line or not lines[location.line] then
    return nil, "location is stale"
  end
  local result = {}
  for index = math.max(1, location.line - radius), math.min(#lines, location.line + radius) do
    table.insert(result, lines[index])
  end
  return result, nil
end

---Re-anchors a location by matching its saved context against current source.
---@param files table[]
---@param location table
---@param context string|nil
---@param radius integer
---@return table|nil
function M.resolve_location(files, location, context, radius)
  local file = locations.file_for(files, location)
  if not file then
    return nil
  end
  local lines = location.side == "old" and file.old_lines or file.new_lines
  if not context or context == "" then
    return lines[location.line] and vim.deepcopy(location) or nil
  end

  local context_lines = vim.split(context, "\n", { plain = true, trimempty = false })
  local anchor_index = location.line - math.max(1, location.line - radius) + 1
  local best_line
  local best_distance
  for start = 1, #lines - #context_lines + 1 do
    local matches = true
    for offset, expected in ipairs(context_lines) do
      if lines[start + offset - 1] ~= expected then
        matches = false
        break
      end
    end
    if matches then
      local candidate = start + anchor_index - 1
      local distance = math.abs(candidate - location.line)
      if not best_distance or distance < best_distance then
        best_line = candidate
        best_distance = distance
      end
    end
  end
  if not best_line then
    return nil
  end
  local resolved = vim.deepcopy(location)
  resolved.line = best_line
  return resolved
end

---@param lines string[]
---@param location table
---@param radius integer
---@return table
function M.context_result(lines, location, radius)
  local start_line = math.max(1, location.line - radius)
  return {
    lines = lines,
    text = table.concat(lines, "\n"),
    start_line = start_line,
    radius = radius,
  }
end

---Builds the public context payload or a structured error for a location.
---@param files table[]
---@param location table
---@param radius integer
---@return table|nil result, table|nil error
function M.context(files, location, radius)
  local lines, err = M.get_context(files, location, radius)
  if not lines then
    return nil, errors.result(err == "file not found" and "file_not_found" or "stale_location", err)
  end
  return M.context_result(lines, location, radius), nil
end

return M

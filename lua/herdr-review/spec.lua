local M = {}

local function endpoint(value)
  if value == "WORKTREE" then
    return { kind = "worktree" }
  end
  return { kind = "ref", name = value }
end

---@param args string[]|nil
---@return table
function M.parse(args)
  args = args or {}
  local value = args[1]
  if not value or value == "" then
    return {
      operator = "..",
      base = endpoint("HEAD"),
      head = endpoint("WORKTREE"),
    }
  end

  local base, _, head = value:match("^(.-)(%.%.%.)(.-)$")
  if base and head and base ~= "" and head ~= "" then
    return { operator = "...", base = endpoint(base), head = endpoint(head) }
  end

  base, _, head = value:match("^(.-)(%.%.)(.-)$")
  if base and head and base ~= "" and head ~= "" then
    return { operator = "..", base = endpoint(base), head = endpoint(head) }
  end

  return {
    operator = "..",
    base = endpoint(value),
    head = endpoint("WORKTREE"),
  }
end

---@param spec table
---@return string
function M.label(spec)
  local function name(point)
    return point.kind == "worktree" and "WORKTREE" or point.name
  end

  return name(spec.base) .. spec.operator .. name(spec.head)
end

local function short_name(point)
  if point.kind == "worktree" then
    return "Worktree"
  end
  if point.name and #point.name == 40 and point.name:match("^%x+$") then
    return point.name:sub(1, 7)
  end
  return point.name
end

---@param name string
---@return string header
function M.header_side(name)
  return "Review Diff: " .. short_name(name)
end

return M

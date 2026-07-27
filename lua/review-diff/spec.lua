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
      old = endpoint("HEAD"),
      new = endpoint("WORKTREE"),
    }
  end

  local old, _, new = value:match("^(.-)(%.%.%.)(.-)$")
  if old and new and old ~= "" and new ~= "" then
    return { operator = "...", old = endpoint(old), new = endpoint(new) }
  end

  old, _, new = value:match("^(.-)(%.%.)(.-)$")
  if old and new and old ~= "" and new ~= "" then
    return { operator = "..", old = endpoint(old), new = endpoint(new) }
  end

  return {
    operator = "..",
    old = endpoint(value),
    new = endpoint("WORKTREE"),
  }
end

---@param spec table
---@return string
function M.label(spec)
  local function name(side)
    return side.kind == "worktree" and "WORKTREE" or side.name
  end

  return name(spec.old) .. spec.operator .. name(spec.new)
end

return M

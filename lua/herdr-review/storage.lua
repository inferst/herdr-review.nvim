local Path = require("plenary.path")
local config = require("herdr-review.config")

local M = {}

---@return string
local function session_file(range)
  return config.data_dir .. "/" .. range:gsub("/", "_") .. ".json"
end

---@return table
function M.load(range)
  local file = Path:new(session_file(range))
  if not file:exists() then
    return { version = 1, range = range, comments = {} }
  end
  local content = file:read()
  if not content or content == "" then
    return { version = 1, range = range, comments = {} }
  end
  return vim.json.decode(content)
end

---@param range string
---@param data table
function M.save(range, data)
  local dir = Path:new(config.data_dir)
  if not dir:exists() then
    dir:mkdir({ parents = true })
  end
  local file = Path:new(session_file(range))
  file:write(vim.json.encode(data), "w")
end

---@return table
function M.add_comment(range, comment)
  local data = M.load(range)
  table.insert(data.comments, comment)
  M.save(range, data)
  return data
end

---@param range string
---@param id string
---@return table
function M.update_comment(range, id, updates)
  local data = M.load(range)
  for i, c in ipairs(data.comments) do
    if c.id == id then
      for k, v in pairs(updates) do
        data.comments[i][k] = v
      end
      break
    end
  end
  M.save(range, data)
  return data
end

---@param range string
---@param id string
---@return table
function M.delete_comment(range, id)
  local data = M.load(range)
  for i, c in ipairs(data.comments) do
    if c.id == id then
      table.remove(data.comments, i)
      break
    end
  end
  M.save(range, data)
  return data
end

---@param range string
---@return table
function M.get_comments(range)
  local data = M.load(range)
  return data.comments or {}
end

---@return string
function M.generate_id()
  return string.lower(vim.fn.system("uuidgen"):gsub("\n", ""))
end

---@param range string
function M.clear(range)
  M.save(range, { version = 1, range = range, comments = {} })
end

return M

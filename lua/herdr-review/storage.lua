local Path = require("plenary.path")
local config = require("herdr-review.config")

local M = {}

local VERSION = 3
local id_counter = 0

---@param range string
---@return table
local function empty_session(range)
  return { version = VERSION, review_id = range, comments = {} }
end

---@param range string
---@return string
local function session_file(range)
  return config.data_dir .. "/sessions/" .. vim.fn.sha256(range) .. ".json"
end

---@param comment table
---@param index integer
---@return string|nil
local function validate_comment(comment, index)
  if type(comment) ~= "table" then
    return string.format("comment %d must be an object", index)
  end
  if type(comment.id) ~= "string" or comment.id == "" then
    return string.format("comment %d has no id", index)
  end
  if type(comment.file) ~= "string" or comment.file == "" then
    return string.format("comment %d has no file", index)
  end
  if comment.side ~= "old" and comment.side ~= "new" then
    return string.format("comment %d has an invalid side", index)
  end
  if type(comment.line) ~= "number" or comment.line < 1 then
    return string.format("comment %d has an invalid line", index)
  end
  if comment.context_start ~= nil and (type(comment.context_start) ~= "number" or comment.context_start < 1) then
    return string.format("comment %d has an invalid context_start", index)
  end
  if type(comment.text) ~= "string" then
    return string.format("comment %d has no text", index)
  end
  return nil
end

---@param range string
---@param data table
---@return string|nil
local function validate_session(range, data)
  if type(data) ~= "table" then
    return "session data must be an object"
  end
  if data.version ~= VERSION then
    return string.format("unsupported session version: %s", tostring(data.version))
  end
  if data.review_id ~= range then
    return "session review_id does not match the requested review_id"
  end
  if type(data.comments) ~= "table" then
    return "session comments must be an array"
  end
  for index, comment in ipairs(data.comments) do
    local err = validate_comment(comment, index)
    if err then
      return err
    end
  end
  return nil
end

---@return string|nil, string|nil
local function read_file(path)
  local file = Path:new(path)
  local ok_exists, exists = pcall(function()
    return file:exists()
  end)
  if not ok_exists then
    return nil, tostring(exists)
  end
  if not exists then
    return nil, nil
  end

  local ok_read, content = pcall(function()
    return file:read()
  end)
  if not ok_read then
    return nil, tostring(content)
  end
  return content, nil
end

---@param range string
---@return table|nil, string|nil
function M.load(range)
  local content, read_err = read_file(session_file(range))
  if read_err then
    return nil, "Could not read review session: " .. read_err
  end
  if not content or content == "" then
    return empty_session(range), nil
  end

  local ok_decode, data = pcall(vim.json.decode, content)
  if not ok_decode then
    return nil, "Could not decode review session: " .. tostring(data)
  end

  local validation_err = validate_session(range, data)
  if validation_err then
    return nil, "Invalid review session: " .. validation_err
  end
  return data, nil
end

---@param range string
---@param data table
---@return boolean, string|nil
function M.save(range, data)
  local validation_err = validate_session(range, data)
  if validation_err then
    return false, "Invalid review session: " .. validation_err
  end

  local dir = Path:new(config.data_dir .. "/sessions")
  local ok_mkdir, mkdir_err = pcall(function()
    dir:mkdir({ parents = true })
  end)
  if not ok_mkdir then
    return false, "Could not create review session directory: " .. tostring(mkdir_err)
  end

  local ok_encode, content = pcall(vim.json.encode, data)
  if not ok_encode then
    return false, "Could not encode review session: " .. tostring(content)
  end

  local file = Path:new(session_file(range))
  local ok_write, write_err = pcall(function()
    file:write(content, "w")
  end)
  if not ok_write then
    return false, "Could not write review session: " .. tostring(write_err)
  end
  return true, nil
end

---@param range string
---@param comment ReviewComment
---@return table|nil, string|nil
function M.add_comment(range, comment)
  local data, load_err = M.load(range)
  if not data then
    return nil, load_err
  end

  table.insert(data.comments, comment)
  local ok, save_err = M.save(range, data)
  if not ok then
    return nil, save_err
  end
  return data, nil
end

---@param range string
---@param id string
---@param updates table
---@return table|nil, string|nil
function M.update_comment(range, id, updates)
  local data, load_err = M.load(range)
  if not data then
    return nil, load_err
  end

  for _, comment in ipairs(data.comments) do
    if comment.id == id then
      for key, value in pairs(updates) do
        comment[key] = value
      end
      break
    end
  end

  local ok, save_err = M.save(range, data)
  if not ok then
    return nil, save_err
  end
  return data, nil
end

---@param range string
---@param id string
---@return table|nil, string|nil
function M.delete_comment(range, id)
  local data, load_err = M.load(range)
  if not data then
    return nil, load_err
  end

  for index, comment in ipairs(data.comments) do
    if comment.id == id then
      table.remove(data.comments, index)
      break
    end
  end

  local ok, save_err = M.save(range, data)
  if not ok then
    return nil, save_err
  end
  return data, nil
end

---@param range string
---@return ReviewComment[]|nil, string|nil
function M.get_comments(range)
  local data, load_err = M.load(range)
  if not data then
    return nil, load_err
  end
  return data.comments, nil
end

---@return string
function M.generate_id()
  id_counter = id_counter + 1
  local seed = table.concat({ os.time(), vim.uv.hrtime(), id_counter, tostring({}) }, ":")
  return vim.fn.sha256(seed)
end

---@param range string
---@return boolean, string|nil
function M.clear(range)
  return M.save(range, empty_session(range))
end

return M

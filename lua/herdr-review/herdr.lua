local M = {}

---@return boolean
function M.is_installed()
  return vim.fn.executable("herdr") == 1
end

---@return boolean, string
function M.check_server()
  if not M.is_installed() then
    return false, "herdr not found in PATH"
  end
  local result = vim.fn.system("herdr status 2>&1")
  if vim.v.shell_error ~= 0 then
    return false, "herdr server not running. Run 'herdr' to start."
  end
  return true, ""
end

---@class HerdrAgent
---@field name string
---@field status string
---@field pane_id string

---@return HerdrAgent[], string
function M.list_agents()
  local ok, result = M.check_server()
  if not ok then
    return {}, result
  end

  local output = vim.fn.system("herdr agent list")
  if vim.v.shell_error ~= 0 then
    return {}, "Failed to list agents"
  end

  local data = vim.json.decode(output)
  if not data or not data.result or not data.result.agents then
    return {}, "No agents available"
  end

  local agents = {}
  for _, agent in ipairs(data.result.agents) do
    table.insert(agents, {
      name = agent.agent,
      status = agent.agent_status,
      pane_id = agent.pane_id,
      cwd = agent.cwd,
    })
  end

  return agents, ""
end

---@param target string
---@param text string
---@return boolean, string
function M.send_prompt(target, text)
  local ok, err = M.check_server()
  if not ok then
    return false, err
  end

  local escaped = vim.fn.shellescape(text)
  local cmd = string.format("herdr agent prompt %s %s", target, escaped)
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return false, "Failed to send prompt: " .. (result or "unknown error")
  end

  return true, ""
end

---@param range string
---@param comments table[]
---@return string
function M.build_prompt(range, comments)
  local lines = {
    "You are reviewing code. Here are the review comments for this diff.",
    "",
    "Diff range: " .. range,
    "",
  }

  for _, c in ipairs(comments) do
    table.insert(lines, "---")
    local file = c.file
    if c.file_old and c.file_old ~= c.file then
      file = c.file_old .. " → " .. c.file
    end
    table.insert(lines, string.format("File: %s (%s, line %d)", file, c.side, c.line_new or c.line_old))
    table.insert(lines, "Comment: " .. c.text)
  end

  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, "Please fix all issues mentioned above.")

  return table.concat(lines, "\n")
end

return M

local prompt = require("herdr-review.prompt")

local M = {}

---@param args string[]
---@return integer code, string stdout, string stderr
function M.run(args)
  local result = vim.system(args, { text = true }):wait()
  return result.code, result.stdout or "", result.stderr or ""
end

---@return boolean
function M.is_installed()
  return vim.fn.executable("herdr") == 1
end

---@return boolean, string
function M.check_server()
  if not M.is_installed() then
    return false, "herdr not found in PATH"
  end

  local code = M.run({ "herdr", "status" })
  if code ~= 0 then
    return false, "herdr server not running. Run 'herdr' to start."
  end
  return true, ""
end

---@class HerdrAgent
---@field name string
---@field status string
---@field pane_id string
---@field cwd string|nil

---@return HerdrAgent[], string
function M.list_agents()
  local ok, err = M.check_server()
  if not ok then
    return {}, err
  end

  local code, output, stderr = M.run({ "herdr", "agent", "list" })
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to list agents"
  end

  local ok_decode, data = pcall(vim.json.decode, output)
  if not ok_decode then
    return {}, "Failed to decode agent list: " .. tostring(data)
  end
  if not data or not data.result or not data.result.agents then
    return {}, "No agents available"
  end

  local agents = {}
  for index, agent in ipairs(data.result.agents) do
    if type(agent.agent) ~= "string" or type(agent.agent_status) ~= "string" or type(agent.pane_id) ~= "string" then
      return {}, "Invalid agent data at index " .. index
    end
    table.insert(agents, {
      name = agent.agent,
      status = agent.agent_status,
      pane_id = agent.pane_id,
      cwd = agent.cwd,
    })
  end
  return agents, ""
end

---@param pane_id string
---@param text string
---@return boolean, string|nil
function M.send_text(pane_id, text)
  local code, _, stderr = M.run({ "herdr", "pane", "send-text", pane_id, text })
  if code ~= 0 then
    return false, stderr ~= "" and stderr or "Failed to stage prompt"
  end
  return true, nil
end

---@param pane_id string
---@return boolean, string|nil
function M.focus_agent(pane_id)
  local code, _, stderr = M.run({ "herdr", "agent", "focus", pane_id })
  if code ~= 0 then
    return false, stderr ~= "" and stderr or "Failed to focus agent"
  end
  return true, nil
end

---@param range string
---@param comments ReviewComment[]
---@return string
function M.build_prompt(range, comments)
  return prompt.build(range, comments)
end

return M

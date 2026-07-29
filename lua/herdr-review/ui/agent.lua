local diff = require("herdr-review.diff")
local herdr = require("herdr-review.herdr")
local session = require("herdr-review.session")
local storage = require("herdr-review.storage")

local M = {}

local function notify_storage_error(err)
  vim.notify(err or "Could not access review session", vim.log.levels.ERROR)
end

---@param range string
---@param agent HerdrAgent
local function send_comments(range, agent)
  local all_comments, storage_err = storage.get_comments(range)
  if not all_comments then
    notify_storage_error(storage_err)
    return
  end
  if #all_comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local fresh_comments = {}
  for _, comment in ipairs(all_comments) do
    if not session.is_stale(comment.id) then
      table.insert(fresh_comments, comment)
    end
  end
  if #fresh_comments == 0 then
    return
  end

  local prompt = herdr.build_prompt(range, fresh_comments)
  local sent, send_err = herdr.send_text(agent.pane_id, prompt)
  if not sent then
    vim.notify(send_err or "Failed to stage prompt", vim.log.levels.ERROR)
    return
  end

  local focused, focus_err = herdr.focus_agent(agent.pane_id)
  if not focused then
    vim.notify(focus_err or "Failed to focus agent", vim.log.levels.ERROR)
    return
  end

  vim.notify(
    string.format("Staged %d comments for %s. Press Enter to send.", #fresh_comments, agent.name),
    vim.log.levels.INFO
  )
end

function M.send_to_agent()
  local range = session.get_current_range()
  if not range then
    vim.notify("No active review session", vim.log.levels.WARN)
    return
  end

  local ok, err = herdr.check_server()
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local view = diff.get_current_view()
  if not view then
    vim.notify("Cannot determine project root", vim.log.levels.ERROR)
    return
  end

  local project_root = view:repo_root()
  if not project_root then
    vim.notify("Cannot determine project root", vim.log.levels.ERROR)
    return
  end

  local agents, agent_err = herdr.list_agents()
  if #agents == 0 then
    vim.notify(agent_err ~= "" and agent_err or "No agents available", vim.log.levels.ERROR)
    return
  end

  local filtered = {}
  for _, agent in ipairs(agents) do
    if agent.cwd and agent.cwd == project_root then
      table.insert(filtered, agent)
    end
  end

  if #filtered == 0 then
    local agent_cwds = {}
    for _, agent in ipairs(agents) do
      table.insert(agent_cwds, agent.name .. "=" .. (agent.cwd or "nil"))
    end
    vim.notify("No agents in " .. project_root .. ". Found: " .. table.concat(agent_cwds, ", "), vim.log.levels.ERROR)
    return
  end

  if #filtered == 1 then
    send_comments(range, filtered[1])
    return
  end

  local names = {}
  for _, agent in ipairs(filtered) do
    table.insert(names, agent.name .. " (" .. agent.pane_id .. ") " .. agent.status)
  end

  vim.ui.select(names, { prompt = "Send to agent:" }, function(choice, index)
    if not choice then
      return
    end
    send_comments(range, filtered[index])
  end)
end

return M

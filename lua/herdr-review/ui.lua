local diff = require("herdr-review.diff")
local storage = require("herdr-review.storage")
local session = require("herdr-review.session")
local herdr = require("herdr-review.herdr")

local M = {}

---@param range string
function M.refresh_all_extmarks(range)
  local comments = storage.get_comments(range)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      session.clear_extmarks(bufnr)
      local file = session.get_buf_file(bufnr)
      for _, c in ipairs(comments) do
        if c.file == file then
          local line = c.side == "new" and c.line_new or c.line_old
          if line then
            session.place_extmark(bufnr, line, c.text)
          end
        end
      end
    end
  end
end

function M.create_comment()
  local file, side, line, file_old = diff.get_cursor_context()
  if not file or not side or not line then
    vim.notify("Not in a diff view", vim.log.levels.WARN)
    return
  end

  local range = session.current_range
  if not range then
    vim.notify("No active review session", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Comment: " }, function(text)
    if not text or text == "" then
      return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local context_lines = diff.get_context(bufnr, line, 3)

    local comment = {
      id = storage.generate_id(),
      file = file,
      file_old = file_old,
      file_new = file,
      line_new = side == "new" and line or nil,
      line_old = side == "old" and line or nil,
      side = side,
      text = text,
      context = table.concat(context_lines, "\n"),
      sent = false,
      sent_at = nil,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    storage.add_comment(range, comment)
    session.place_extmark(bufnr, line, text)
    vim.notify("Comment added", vim.log.levels.INFO)
  end)
end

function M.open_list()
  local range = session.current_range
  if not range then
    vim.notify("No active review session", vim.log.levels.WARN)
    return
  end

  local comments = storage.get_comments(range)
  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local sent_count = 0
  for _, c in ipairs(comments) do
    if c.sent then
      sent_count = sent_count + 1
    end
  end

  local lines = {}
  table.insert(lines, string.format("─── Review: %s ─── %d comments (%d sent) ───", range, #comments, sent_count))
  table.insert(lines, "")

  for i, c in ipairs(comments) do
    local file = c.file
    if c.file_old and c.file_old ~= c.file then
      file = c.file_old .. " → " .. c.file
    end
    local line_num = c.side == "new" and c.line_new or c.line_old
    local marker = c.sent and " ✓" or ""
    table.insert(lines, string.format("  %d  %s:%d (%s)  \"%s\"%s", i, file, line_num, c.side, c.text, marker))
  end

  table.insert(lines, "")
  table.insert(lines, "  [e]dit  [d]elete  [⏎]jump  [q]close")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "herdr-review-list"

  local width = 0
  for _, l in ipairs(lines) do
    if #l > width then
      width = #l
    end
  end
  width = math.min(width + 4, vim.o.columns - 4)
  local height = #lines

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Review Comments ",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })

  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local idx = cursor[1] - 2
    if idx < 1 or idx > #comments then
      return
    end
    local c = comments[idx]
    vim.api.nvim_win_close(win, true)
    M.jump_to_comment(c)
  end, { buffer = buf })

  vim.keymap.set("n", "e", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local idx = cursor[1] - 2
    if idx < 1 or idx > #comments then
      return
    end
    local c = comments[idx]
    M.edit_comment(range, c, win, comments)
  end, { buffer = buf })

  vim.keymap.set("n", "d", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local idx = cursor[1] - 2
    if idx < 1 or idx > #comments then
      return
    end
    local c = comments[idx]
    storage.delete_comment(range, c.id)
    M.refresh_all_extmarks(range)
    vim.api.nvim_win_close(win, true)
    M.open_list()
  end, { buffer = buf })
end

---@param comment table
function M.jump_to_comment(comment)
  local view = diff.get_current_view()
  if not view then
    return
  end

  local target_win = (comment.side == "old") and view.cur_layout.a or view.cur_layout.b
  if not target_win then
    return
  end

  vim.api.nvim_set_current_win(target_win.id)

  local line = comment.side == "new" and comment.line_new or comment.line_old
  if line then
    vim.api.nvim_win_set_cursor(target_win.id, { line, 0 })
  end
end

---@param range string
---@param comment table
---@param list_win integer
---@param comments table[]
function M.edit_comment(range, comment, list_win, comments)
  vim.ui.input({ prompt = "Edit comment: ", default = comment.text }, function(text)
    if not text or text == "" then
      return
    end
    storage.update_comment(range, comment.id, { text = text })
    M.refresh_all_extmarks(range)
    vim.api.nvim_win_close(list_win, true)
    M.open_list()
  end)
end

function M.send_to_agent()
  local range = session.current_range
  if not range then
    vim.notify("No active review session", vim.log.levels.WARN)
    return
  end

  local ok, err = herdr.check_server()
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local agents, agent_err = herdr.list_agents()
  if #agents == 0 then
    vim.notify(agent_err ~= "" and agent_err or "No agents available", vim.log.levels.ERROR)
    return
  end

  local names = {}
  for _, a in ipairs(agents) do
    table.insert(names, a.name .. " (" .. a.status .. ")")
  end

  vim.ui.select(names, { prompt = "Send to agent:" }, function(choice, idx)
    if not choice then
      return
    end

    local agent = agents[idx]
    local all_comments = storage.get_comments(range)
    local unsent = {}
    for _, c in ipairs(all_comments) do
      if not c.sent then
        table.insert(unsent, c)
      end
    end

    if #unsent == 0 then
      vim.notify("No unsent comments", vim.log.levels.INFO)
      return
    end

    local prompt = herdr.build_prompt(range, unsent)
    local send_ok, send_err = herdr.send_prompt(agent.name, prompt)
    if not send_ok then
      vim.notify(send_err, vim.log.levels.ERROR)
      return
    end

    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    for _, c in ipairs(unsent) do
      storage.update_comment(range, c.id, { sent = true, sent_at = now })
    end

    vim.notify(string.format("Sent %d comments to %s", #unsent, agent.name), vim.log.levels.INFO)
  end)
end

return M

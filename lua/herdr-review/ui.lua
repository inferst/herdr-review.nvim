local config = require("herdr-review.config")
local diff = require("herdr-review.diff")
local storage = require("herdr-review.storage")
local session = require("herdr-review.session")
local herdr = require("herdr-review.herdr")

local M = {}

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

  local existing_comment = nil
  for _, c in ipairs(storage.get_comments(range)) do
    if c.file_new == file and c.side == side then
      local target_line = side == "new" and c.line_new or c.line_old
      if target_line and target_line == line then
        existing_comment = c
        break
      end
    end
  end

  vim.ui.input({
    prompt = existing_comment and "Edit comment: " or "Comment: ",
    default = existing_comment and existing_comment.text or "",
  }, function(text)
    if not text or text == "" then
      return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local context_lines = diff.get_context(bufnr, line, 3)
    local context = table.concat(context_lines, "\n")

    if existing_comment then
      storage.update_comment(range, existing_comment.id, { text = text, context = context })
      vim.notify("Comment updated", vim.log.levels.INFO)
    else
      local comment = {
        id = storage.generate_id(),
        file = file,
        file_old = file_old,
        file_new = file,
        line_new = side == "new" and line or nil,
        line_old = side == "old" and line or nil,
        side = side,
        text = text,
        context = context,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      }
      storage.add_comment(range, comment)
      vim.notify("Comment added", vim.log.levels.INFO)
    end
    session.load_session(range)
  end)
end

local function wrap_text(text, max_width)
  local result = {}
  while #text > 0 do
    if #text <= max_width then
      table.insert(result, text)
      break
    end
    local sub = text:sub(1, max_width + 1)
    local space = sub:match("^.*()%s")
    if space and space > 1 then
      table.insert(result, text:sub(1, space - 1))
      text = text:sub(space + 1)
    else
      table.insert(result, text:sub(1, max_width))
      text = text:sub(max_width + 1)
    end
  end
  return result
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

  local list_width = config.list_width
  local text_width = list_width - 6
  local lines = {}
  local row_to_idx = {}

  table.insert(lines, string.format("─── Review: %s ─── %d comments ───", range, #comments))
  table.insert(lines, "")

  for i, c in ipairs(comments) do
    local file = c.file
    if c.file_old and c.file_old ~= c.file then
      file = c.file_old .. " → " .. c.file
    end
    local line_num = c.side == "new" and c.line_new or c.line_old
    local header = string.format("  %d  %s:%d (%s)", i, file, line_num, c.side)
    table.insert(lines, header)
    row_to_idx[#lines] = i

    local wrapped = wrap_text(c.text, text_width)
    for _, chunk in ipairs(wrapped) do
      table.insert(lines, "    " .. chunk)
      row_to_idx[#lines] = i
    end
  end

  table.insert(lines, "")
  table.insert(lines, "  [e]dit  [d]elete  [⏎]jump  [q]close")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "herdr-review-list"

  local width = math.min(list_width, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  height = math.max(height, 5)

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Review Comments ",
    title_pos = "center",
  })

  local function cursor_idx()
    local cursor = vim.api.nvim_win_get_cursor(win)
    for r = cursor[1], 1, -1 do
      if row_to_idx[r] then
        return row_to_idx[r]
      end
    end
    return nil
  end

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })

  vim.keymap.set("n", "<CR>", function()
    local idx = cursor_idx()
    if not idx then
      return
    end
    local c = comments[idx]
    vim.api.nvim_win_close(win, true)
    M.jump_to_comment(c)
  end, { buffer = buf })

  vim.keymap.set("n", "e", function()
    local idx = cursor_idx()
    if not idx then
      return
    end
    local c = comments[idx]
    M.edit_comment(range, c, win, comments)
  end, { buffer = buf })

  vim.keymap.set("n", "d", function()
    local idx = cursor_idx()
    if not idx then
      return
    end
    local c = comments[idx]
    storage.delete_comment(range, c.id)
    session.load_session(range)
    vim.api.nvim_win_close(win, true)
    M.open_list()
  end, { buffer = buf })
end

---@param comment table
function M.jump_to_comment(comment)
  local target_file = comment.file_new
  if not target_file then
    return
  end

  local match_file = comment.side == "new" and comment.file_new or comment.file_old
  if not match_file then
    match_file = comment.file_new
  end

  local function strip_path(p)
    return p:sub(1, 2) == "./" and p:sub(3) or p
  end

  target_file = strip_path(target_file)
  match_file = strip_path(match_file)

  local function panel_win(view)
    if not view or not view.cur_layout then
      return nil
    end
    local panel = comment.side == "new" and view.cur_layout.b or view.cur_layout.a
    if not panel or not panel.id then
      return nil
    end
    local panel_path = panel.file and (type(panel.file) == "string" and panel.file or panel.file.path)
    if not panel_path then
      return nil
    end
    if strip_path(panel_path) ~= match_file then
      return nil
    end
    return panel.id
  end

  local function focus_win(win_id)
    vim.api.nvim_set_current_win(win_id)
    local line = comment.side == "new" and comment.line_new or comment.line_old
    if line then
      pcall(vim.api.nvim_win_set_cursor, win_id, { line, 0 })
    end
  end

  local view = diff.get_current_view()
  local wid = view and panel_win(view)
  if wid then
    focus_win(wid)
    return
  end

  if view and view.set_file_by_path then
    view:set_file_by_path(target_file, true, true)

    local function try_focus(attempts)
      if attempts <= 0 then
        vim.notify("Could not find window for " .. target_file, vim.log.levels.WARN)
        return
      end
      vim.schedule(function()
        local w = panel_win(diff.get_current_view())
        if w then
          focus_win(w)
        else
          try_focus(attempts - 1)
        end
      end)
    end

    try_focus(10)
    return
  end

  vim.notify("Could not find window for " .. target_file, vim.log.levels.WARN)
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
    session.load_session(range)
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

  local view = diff.get_current_view()
  if not view or not view.adapter or not view.adapter.ctx then
    vim.notify("Cannot determine project root", vim.log.levels.ERROR)
    return
  end

  local project_root = view.adapter.ctx.toplevel
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
  for _, a in ipairs(agents) do
    if a.cwd and a.cwd == project_root then
      table.insert(filtered, a)
    end
  end

  if #filtered == 0 then
    local agent_cwds = {}
    for _, a in ipairs(agents) do
      table.insert(agent_cwds, a.name .. "=" .. (a.cwd or "nil"))
    end
    vim.notify("No agents in " .. project_root .. ". Found: " .. table.concat(agent_cwds, ", "), vim.log.levels.ERROR)
    return
  end

  local function do_send(agent)
    local all_comments = storage.get_comments(range)
    if #all_comments == 0 then
      vim.notify("No comments", vim.log.levels.INFO)
      return
    end

    local prompt = herdr.build_prompt(range, all_comments)

    local text_cmd = string.format("herdr pane send-text %s %s", agent.pane_id, vim.fn.shellescape(prompt))
    vim.fn.system(text_cmd)
    if vim.v.shell_error ~= 0 then
      vim.notify("Failed to stage prompt", vim.log.levels.ERROR)
      return
    end

    local focus_cmd = string.format("herdr agent focus %s", agent.pane_id)
    vim.fn.system(focus_cmd)

    vim.notify(string.format("Staged %d comments for %s. Press Enter to send.", #all_comments, agent.name), vim.log.levels.INFO)
  end

  if #filtered == 1 then
    do_send(filtered[1])
    return
  end

  local names = {}
  for _, a in ipairs(filtered) do
    table.insert(names, a.name .. " (" .. a.pane_id .. ") " .. a.status)
  end

  vim.ui.select(names, { prompt = "Send to agent:" }, function(choice, idx)
    if not choice then
      return
    end
    do_send(filtered[idx])
  end)
end

return M

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

local function truncate_text(text, max_width)
  if max_width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  if max_width == 1 then
    return "…"
  end
  return vim.fn.strcharpart(text, 0, max_width - 1) .. "…"
end

local function sorted_comments(range)
  local comments = storage.get_comments(range)
  table.sort(comments, function(a, b)
    local a_file = a.file or a.file_new or a.file_old or ""
    local b_file = b.file or b.file_new or b.file_old or ""
    if a_file ~= b_file then
      return a_file < b_file
    end

    local a_side = a.side == "old" and 1 or 2
    local b_side = b.side == "old" and 1 or 2
    if a_side ~= b_side then
      return a_side < b_side
    end

    local a_line = a.side == "new" and a.line_new or a.line_old or math.huge
    local b_line = b.side == "new" and b.line_new or b.line_old or math.huge
    if a_line ~= b_line then
      return a_line < b_line
    end

    return (a.id or "") < (b.id or "")
  end)
  return comments
end

function M.open_list()
  local range = session.current_range
  if not range then
    vim.notify("No active review session", vim.log.levels.WARN)
    return
  end

  local comments = sorted_comments(range)
  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local list_width = config.list_width
  local width = math.min(list_width, vim.o.columns - 4)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "herdr-review-list"
  vim.bo[buf].swapfile = false

  local function window_height()
    return math.max(1, math.min(#comments, vim.o.lines - 4))
  end

  local height = window_height()
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
    title = string.format(" Comments · %d ", #comments),
    title_pos = "center",
  })

  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"

  local function render(selected_id, selected_row)
    comments = sorted_comments(range)
    if #comments == 0 then
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      vim.notify("No comments", vim.log.levels.INFO)
      return
    end
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    local lines = {}
    for _, c in ipairs(comments) do
      local file
      if c.side == "old" then
        file = c.file_old or c.file or c.file_new
      else
        file = c.file_new or c.file
      end
      file = file or "?"

      local line_num = c.side == "new" and c.line_new or c.line_old
      local marker = c.side == "new" and "+" or "−"
      local prefix = string.format("%s:%s  %s  ", file, line_num or "?", marker)
      local text_width = width - vim.fn.strdisplaywidth(prefix)
      local text = truncate_text(c.text or "", text_width)
      table.insert(lines, truncate_text(prefix, width - vim.fn.strdisplaywidth(text)) .. text)
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_win_set_config(win, { title = string.format(" Comments · %d ", #comments) })
    vim.api.nvim_win_set_height(win, window_height())

    local cursor_row = selected_row or 1
    if selected_id then
      for i, c in ipairs(comments) do
        if c.id == selected_id then
          cursor_row = i
          break
        end
      end
    end
    cursor_row = math.max(1, math.min(cursor_row, #comments))
    vim.api.nvim_win_set_cursor(win, { cursor_row, 0 })
  end

  local function cursor_idx()
    return vim.api.nvim_win_get_cursor(win)[1]
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", function()
    close()
  end, { buffer = buf })

  vim.keymap.set("n", "<Esc>", function()
    close()
  end, { buffer = buf })

  vim.keymap.set("n", "<CR>", function()
    local idx = cursor_idx()
    if not idx then
      return
    end
    local c = comments[idx]
    close()
    M.jump_to_comment(c)
  end, { buffer = buf })

  vim.keymap.set("n", "e", function()
    local idx = cursor_idx()
    if not idx then
      return
    end
    local c = comments[idx]
    M.edit_comment(range, c, win, function(selected_id)
      render(selected_id)
    end)
  end, { buffer = buf })

  vim.keymap.set("n", "d", function()
    local idx = cursor_idx()
    if not idx then
      return
    end
    local c = comments[idx]
    storage.delete_comment(range, c.id)
    session.load_session(range)
    render(nil, math.min(idx, #comments - 1))
  end, { buffer = buf })

  render()
end

---@param comment table
function M.jump_to_comment(comment)
  local target_file = comment.file_new
  if not target_file then
    return
  end

  local function strip_path(p)
    return p:sub(1, 2) == "./" and p:sub(3) or p
  end

  target_file = strip_path(target_file)

  local function focus_win(win_id)
    vim.api.nvim_set_current_win(win_id)
    local line = comment.side == "new" and comment.line_new or comment.line_old
    if line then
      pcall(vim.api.nvim_win_set_cursor, win_id, { line, 0 })
    end
  end

  local function layout_panel(view)
    if not view or not view.cur_layout then
      return nil
    end
    return comment.side == "new" and view.cur_layout.b or view.cur_layout.a
  end

  local function find_entry(view)
    for _, file in view.files:iter() do
      local fp = type(file.path) == "string" and file.path or tostring(file.path)
      if strip_path(fp) == target_file then
        return file
      end
    end
    return nil
  end

  local view = diff.get_current_view()
  if not view then
    vim.notify("No diff view open", vim.log.levels.WARN)
    return
  end

  local panel = layout_panel(view)
  if panel and panel.id and vim.api.nvim_win_is_valid(panel.id) then
    local fp = panel.file and (type(panel.file) == "string" and panel.file or panel.file.path)
    if fp and strip_path(fp) == target_file then
      focus_win(panel.id)
      return
    end
  end

  local file = find_entry(view)
  if not file then
    vim.notify("Could not find file " .. target_file, vim.log.levels.WARN)
    return
  end

  local future = view:set_file_by_path(target_file, false, false)
  future:finally(function()
    local current_view = diff.get_current_view()
    local panel = layout_panel(current_view)
    if not panel or not panel.id or not vim.api.nvim_win_is_valid(panel.id) then
      vim.notify("Could not find window for " .. target_file, vim.log.levels.WARN)
      return
    end
    focus_win(panel.id)
  end)
end

---@param range string
---@param comment table
---@param list_win integer
---@param refresh fun(selected_id: string)|nil
function M.edit_comment(range, comment, list_win, refresh)
  vim.ui.input({ prompt = "Edit comment: ", default = comment.text }, function(text)
    if not text or text == "" then
      return
    end
    storage.update_comment(range, comment.id, { text = text })
    session.load_session(range)
    if refresh then
      refresh(comment.id)
    elseif vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_close(list_win, true)
      M.open_list()
    end
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

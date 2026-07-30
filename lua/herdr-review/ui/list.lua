local comments = require("herdr-review.comments")
local config = require("herdr-review.config")
local diff = require("herdr-review.diff")
local session = require("herdr-review.session")
local util = require("herdr-review.ui.util")

local M = {}

---@param range string
---@return ReviewComment[]|nil
local function load_comments(range)
  local stored = util.load_comments(range)
  if not stored then
    return nil
  end
  local sorted = comments.sort(stored)
  for _, comment in ipairs(sorted) do
    comment.stale = session.is_stale(comment.id)
  end
  return sorted
end

---@param text string
---@param max_width integer
---@return string
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

---@param comment ReviewComment
---@param width integer
---@return string
local function render_comment(comment, width)
  local marker = comment.side == "new" and "+" or "−"
  local stale = comment.stale and " [stale]" or ""
  local prefix = string.format("%s:%s  %s%s  ", comment.file, comment.line, marker, stale)
  local text_width = width - vim.fn.strdisplaywidth(prefix)
  local text = truncate_text(comment.text, text_width)
  return truncate_text(prefix, width - vim.fn.strdisplaywidth(text)) .. text
end

---@param comment ReviewComment
function M.jump_to_comment(comment)
  local view = diff.get_current_view()
  if not view then
    vim.notify("No diff view open", vim.log.levels.WARN)
    return
  end
  local location = session.resolve_comment(comment)
  if not location then
    return
  end
  local ok, err = view:open_location(location)
  if not ok then
    vim.notify(err or "Could not find comment location", vim.log.levels.WARN)
  end
end

function M.open_list()
  local range = session.get_current_range()
  if not range then
    vim.notify("No active review session", vim.log.levels.WARN)
    return
  end

  local loaded_comments = load_comments(range)
  if not loaded_comments then
    return
  end
  if #loaded_comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local list_width = config.list_width
  local width = math.min(list_width, math.max(1, vim.o.columns - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "herdr-review-list"
  vim.bo[buf].swapfile = false

  local function window_height()
    return math.max(1, math.min(#loaded_comments, vim.o.lines - 4))
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
    title = string.format(" Comments · %d ", #loaded_comments),
    title_pos = "center",
  })

  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"

  local function render(selected_id, selected_row)
    local refreshed = load_comments(range)
    if not refreshed then
      return
    end
    loaded_comments = refreshed

    if #loaded_comments == 0 then
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
    for _, comment in ipairs(loaded_comments) do
      table.insert(lines, render_comment(comment, width))
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_win_set_config(win, { title = string.format(" Comments · %d ", #loaded_comments) })
    vim.api.nvim_win_set_height(win, window_height())

    local cursor_row = selected_row or 1
    if selected_id then
      for index, comment in ipairs(loaded_comments) do
        if comment.id == selected_id then
          cursor_row = index
          break
        end
      end
    end
    cursor_row = math.max(1, math.min(cursor_row, #loaded_comments))
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

  vim.keymap.set("n", "q", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })

  vim.keymap.set("n", "<CR>", function()
    local comment = loaded_comments[cursor_idx()]
    if not comment then
      return
    end
    close()
    M.jump_to_comment(comment)
  end, { buffer = buf })

  vim.keymap.set("n", "e", function()
    local comment = loaded_comments[cursor_idx()]
    if not comment then
      return
    end
    require("herdr-review.ui.comments").edit_comment(range, comment, win, function(selected_id)
      render(selected_id)
    end)
  end, { buffer = buf })

  vim.keymap.set("n", "d", function()
    local index = cursor_idx()
    local comment = loaded_comments[index]
    if not comment then
      return
    end

    local data, err = session.delete_comment(range, comment.id)
    if not data then
      util.notify_storage_error(err)
      return
    end
    render(nil, math.min(index, #loaded_comments - 1))
  end, { buffer = buf })

  render()
end

return M

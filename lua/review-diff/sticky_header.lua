local layout = require("review-diff.layout")
local render = require("review-diff.render")

local M = {}

local namespace = vim.api.nvim_create_namespace("review-diff-sticky-header")

local function valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function header_at_top(view, top_line)
  local row = view.display_rows and view.display_rows[top_line]
  if not row or not row.file_id then
    return nil
  end

  local range = view.file_row_ranges and view.file_row_ranges[row.file_id]
  if not range or top_line <= range.start then
    return nil
  end

  local header = view.display_rows[range.start]
  if header and header.display_kind == "file_header" then
    return header
  end
  return nil
end

local function close_window(item)
  if valid_window(item.win) then
    vim.api.nvim_win_close(item.win, true)
  end
  item.win = nil
end

local function ensure_buffer(item)
  if item.buf and vim.api.nvim_buf_is_valid(item.buf) then
    return item.buf
  end

  item.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[item.buf].buflisted = false
  vim.bo[item.buf].buftype = "nofile"
  vim.bo[item.buf].bufhidden = "hide"
  vim.bo[item.buf].swapfile = false
  vim.bo[item.buf].modifiable = false
  return item.buf
end

local function set_highlights(bufnr, row, side, opts, text)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  local line_hl, inline = render.highlight(row, side, opts)
  if line_hl then
    vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, 0, {
      end_row = 0,
      end_col = #text,
      hl_group = line_hl,
      priority = 50,
    })
  end
  if not inline then
    return
  end

  local items = inline.hl_group and { inline } or inline
  for _, item in ipairs(items) do
    if item.finish > item.start then
      vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, item.start, {
        end_row = 0,
        end_col = item.finish,
        hl_group = item.hl_group,
        priority = 80,
      })
    end
  end
end

local function render_header(item, row, side, opts)
  local text = render.text(row, side)
  if item.text == text and item.buf and vim.api.nvim_buf_is_valid(item.buf) then
    return
  end

  local bufnr = ensure_buffer(item)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
  vim.bo[bufnr].modifiable = false
  set_highlights(bufnr, row, side, opts, text)
  item.text = text
end

local function source_view(win)
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return nil
  end
  return { top_line = info.topline, leftcol = info.leftcol or 0 }
end

local function show(item, source_win, source_viewport)
  local config = {
    relative = "win",
    win = source_win,
    row = 0,
    col = 0,
    width = vim.api.nvim_win_get_width(source_win),
    height = 1,
    focusable = false,
    style = "minimal",
    border = "none",
    zindex = 50,
  }

  if valid_window(item.win) then
    vim.api.nvim_win_set_config(item.win, config)
  else
    item.win = vim.api.nvim_open_win(ensure_buffer(item), false, config)
    vim.wo[item.win].winhighlight = "Normal:Normal,NormalFloat:Normal"
  end

  vim.api.nvim_win_call(item.win, function()
    vim.fn.winrestview({ leftcol = source_viewport.leftcol })
  end)
end

local function update_side(view, side)
  local item = view.sticky_headers[side]
  local source_win = view[side .. "_win"]
  if not layout.valid_window(source_win) then
    close_window(item)
    return
  end

  local viewport = source_view(source_win)
  local header = viewport and header_at_top(view, viewport.top_line)
  if not header then
    close_window(item)
    return
  end

  render_header(item, header, side, view.options)
  show(item, source_win, viewport)
end

---@param view table
function M.update(view)
  if not view.sticky_headers then
    return
  end
  if not view.options.sticky_file_header then
    for _, item in pairs(view.sticky_headers) do
      close_window(item)
    end
    return
  end

  for _, side in ipairs({ "old", "new" }) do
    update_side(view, side)
  end
end

---@param view table
function M.dispose(view)
  if not view.sticky_headers then
    return
  end
  for _, item in pairs(view.sticky_headers) do
    close_window(item)
    if item.buf and vim.api.nvim_buf_is_valid(item.buf) then
      vim.api.nvim_buf_delete(item.buf, { force = true })
    end
  end
  view.sticky_headers = nil
end

---@param view table
function M.attach(view)
  view.sticky_headers = {
    old = {},
    new = {},
  }
  view:on("rendered", M.update)
  view:on("closed", M.dispose)
end

return M

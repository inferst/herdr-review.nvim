local layout = require("review-diff.layout")
local errors = require("review-diff.errors")

local M = {}

function M.add(view, action)
  if not action or not action.id or not action.key or not action.callback then
    return false, errors.result("invalid_action", "Invalid review action")
  end
  view.actions = view.actions or {}
  if view.actions[action.id] then
    return false, errors.result("action_key_conflict", "Review action is already registered")
  end
  view.actions[action.id] = action.label or action.desc or action.id
  view:map({
    key = action.key,
    action = action.label or action.desc or action.id,
    desc = action.desc or action.label or action.id,
    callback = function()
      action.callback(view)
    end,
  })
  return true, nil
end

function M.set_all(view, actions)
  for _, action in ipairs(actions or {}) do
    local ok, err = M.add(view, action)
    if not ok then
      return false, err
    end
  end
  return true, nil
end

function M.setup_defaults(view, default_keymaps)
  local function mapping(name, callback, desc)
    local key = default_keymaps[name]
    if key then
      view:map({ key = key, callback = callback, desc = desc, action = desc })
    end
  end
  mapping("toggle_file", function()
    view:toggle_file_at_cursor()
  end, "Toggle file")
  mapping("open_file", function()
    view:open_source_at_cursor()
  end, "Open worktree file")
  mapping("help", function()
    view:show_help()
  end, "Show keymaps")
  mapping("close", function()
    view:close()
  end, "Close review")
  mapping("refresh", function()
    view:request_refresh()
  end, "Refresh review")
  mapping("next_file", function()
    view:move_file(1)
  end, "Next file")
  mapping("previous_file", function()
    view:move_file(-1)
  end, "Previous file")
  mapping("next_hunk", function()
    view:move_hunk(1)
  end, "Next hunk")
  mapping("previous_hunk", function()
    view:move_hunk(-1)
  end, "Previous hunk")
  mapping("toggle_fold", function()
    view:toggle_fold_at_cursor()
  end, "Toggle context fold")
  mapping("toggle_all", function()
    view:toggle_all()
  end, "Toggle expand/collapse all")
  mapping("expand_all", function()
    view:expand_all()
  end, "Expand all")
  mapping("collapse_all", function()
    view:collapse_all()
  end, "Collapse all")
end

function M.show_help(view)
  local lines = { "Review Diff keymaps", "" }
  local keys = {}
  for key, action in pairs(view.keymaps) do
    table.insert(keys, { key = key, action = action })
  end
  table.sort(keys, function(left, right)
    return left.key < right.key
  end)
  for _, item in ipairs(keys) do
    table.insert(lines, string.format("%-12s %s", item.key, item.action))
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = math.min(width + 2, vim.o.columns - 4),
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Review Diff ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  local close = function()
    if layout.valid_window(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "?", close, { buffer = bufnr, silent = true })
end

return M

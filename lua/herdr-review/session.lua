local config = require("herdr-review.config")
local diff = require("herdr-review.diff")
local storage = require("herdr-review.storage")

local M = {}

---@type string|nil
M.current_range = nil

---@param bufnr integer
---@param line integer
---@param text string
function M.place_extmark(bufnr, line, text)
  vim.api.nvim_buf_set_extmark(bufnr, config.ns, line - 1, 0, {
    virt_text = { { text, "Comment" } },
    virt_text_pos = "eol",
  })
end

---@param bufnr integer
function M.clear_extmarks(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)
end

---@return string|nil
function M.get_commit_range()
  local view = diff.get_current_view()
  if not view then
    return nil
  end

  if view.rev_arg then
    return view.rev_arg
  end

  local left = view.left
  local right = view.right

  if not left or not right then
    return nil
  end

  local left_str = ""
  local right_str = ""

  if left.commit then
    left_str = string.sub(left.commit, 1, 7)
  elseif left.type == 1 then
    left_str = "WORKDIR"
  elseif left.type == 3 then
    left_str = "INDEX"
  end

  if right.commit then
    right_str = string.sub(right.commit, 1, 7)
  elseif right.type == 1 then
    right_str = "WORKDIR"
  elseif right.type == 3 then
    right_str = "INDEX"
  end

  if left_str == "" or right_str == "" then
    return nil
  end

  return left_str .. ".." .. right_str
end

---@param bufnr integer
---@return string|nil
function M.get_buf_file(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end

  local view = diff.get_current_view()
  if not view then
    return nil
  end

  local toplevel = ""
  if view.adapter and view.adapter.ctx then
    toplevel = view.adapter.ctx.toplevel or ""
  end

  if toplevel ~= "" and name:sub(1, #toplevel) == toplevel then
    return name:sub(#toplevel + 2)
  end

  return name
end

---@param range string
function M.load_session(range)
  M.current_range = range
  local comments = storage.get_comments(range)

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.clear_extmarks(bufnr)
      for _, c in ipairs(comments) do
        if c.file == M.get_buf_file(bufnr) then
          local line = c.side == "new" and c.line_new or c.line_old
          if line then
            M.place_extmark(bufnr, line, c.text)
          end
        end
      end
    end
  end
end

function M.on_view_opened()
  local range = M.get_commit_range()
  if range then
    M.load_session(range)
  end
end

function M.on_buf_enter(bufnr)
  if not M.current_range then
    return
  end

  local comments = storage.get_comments(M.current_range)
  local file = M.get_buf_file(bufnr)
  if not file then
    return
  end

  M.clear_extmarks(bufnr)
  for _, c in ipairs(comments) do
    if c.file == file then
      local line = c.side == "new" and c.line_new or c.line_old
      if line then
        M.place_extmark(bufnr, line, c.text)
      end
    end
  end
end

return M

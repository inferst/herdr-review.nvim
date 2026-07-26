local config = require("herdr-review.config")
local diff = require("herdr-review.diff")
local storage = require("herdr-review.storage")

local M = {}

---@type string|nil
M.current_range = nil

local function path_strip_prefix(p)
  if p:sub(1, 2) == "./" then return p:sub(3) end
  return p
end

local function apply_comments(bufnr, comments, file)
  M.clear_extmarks(bufnr)
  file = file or diff.get_buf_path(bufnr) or M.get_buf_file(bufnr)
  if not file then return end
  file = path_strip_prefix(file)
  local buf_side = diff.get_buf_side(bufnr)
  for _, c in ipairs(comments) do
    if path_strip_prefix(c.file) == file then
      if not buf_side or buf_side == c.side then
        local line = c.side == "new" and c.line_new or c.line_old
        if line then
          M.place_extmark(bufnr, line, c.text)
        end
      end
    end
  end
end

---@param bufnr integer
---@param line integer
---@param text string
function M.place_extmark(bufnr, line, text)
  if line < 1 or line > vim.api.nvim_buf_line_count(bufnr) then
    return
  end
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

  if name:sub(1, 11) == "diffview://" then
    local git_pos = name:find("/.git/", 12, true)
    if git_pos then
      local rel_start = name:find("/", git_pos + 5, true)
      if rel_start then
        return name:sub(rel_start + 1)
      end
    end
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
      apply_comments(bufnr, comments)
    end
  end
end

function M.on_view_opened()
  local range = M.get_commit_range()
  if not range then return end

  if M.current_range and range ~= M.current_range then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        M.clear_extmarks(bufnr)
      end
    end
  end

  M.load_session(range)
end

function M.on_buf_enter(bufnr, file)
  local range = M.get_commit_range()

  if range then
    if M.current_range ~= range then
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          M.clear_extmarks(b)
        end
      end
      M.load_session(range)
    end
    apply_comments(bufnr, storage.get_comments(range), file)
    return
  end

  if M.current_range then
    apply_comments(bufnr, storage.get_comments(M.current_range), file)
  end
end

function M.on_view_closed()
  M.current_range = nil
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.clear_extmarks(bufnr)
    end
  end
end

return M

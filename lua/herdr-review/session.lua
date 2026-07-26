local config = require("herdr-review.config")
local diff = require("herdr-review.diff")
local paths = require("herdr-review.paths")
local storage = require("herdr-review.storage")

local M = {}

local state = {
  current_range = nil,
}

---@param bufnr integer
---@param comments ReviewComment[]
---@param file string|nil
local function apply_comments(bufnr, comments, file)
  M.clear_extmarks(bufnr)
  file = file or diff.get_buf_path(bufnr) or M.get_buf_file(bufnr)
  if not file then
    return
  end

  local side = diff.get_buf_side(bufnr)
  for _, comment in ipairs(comments) do
    if paths.equal(comment.file, file) and (not side or side == comment.side) then
      M.place_extmark(bufnr, comment.line, comment.text)
    end
  end
end

local function clear_all_extmarks()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.clear_extmarks(bufnr)
    end
  end
end

---@param message string
local function report_storage_error(message)
  vim.notify(message, vim.log.levels.ERROR)
end

---@return string|nil
function M.get_current_range()
  return state.current_range
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

  local function revision_name(revision)
    if revision.commit then
      return string.sub(revision.commit, 1, 7)
    end
    if revision.type == 1 then
      return "WORKDIR"
    end
    if revision.type == 3 then
      return "INDEX"
    end
    return ""
  end

  local left_name = revision_name(left)
  local right_name = revision_name(right)
  if left_name == "" or right_name == "" then
    return nil
  end
  return left_name .. ".." .. right_name
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
---@return boolean
function M.load_session(range)
  local comments, err = storage.get_comments(range)
  if not comments then
    report_storage_error(err)
    return false
  end

  state.current_range = range
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      apply_comments(bufnr, comments)
    end
  end
  return true
end

function M.on_view_opened()
  local range = M.get_commit_range()
  if not range then
    return
  end

  if state.current_range and range ~= state.current_range then
    clear_all_extmarks()
    state.current_range = nil
  end
  M.load_session(range)
end

---@param bufnr integer
---@param file string|nil
function M.on_buf_enter(bufnr, file)
  local range = M.get_commit_range()
  if range and state.current_range ~= range then
    clear_all_extmarks()
    state.current_range = nil
    if not M.load_session(range) then
      return
    end
  end

  local active_range = range or state.current_range
  if not active_range then
    return
  end

  local comments, err = storage.get_comments(active_range)
  if not comments then
    report_storage_error(err)
    return
  end
  apply_comments(bufnr, comments, file)
end

function M.reset()
  state.current_range = nil
  clear_all_extmarks()
end

function M.on_view_closed()
  M.reset()
end

return M

local storage = require("herdr-review.storage")
local viewer = require("review-diff")

local M = {}

local state = {
  current_range = nil,
  current_view = nil,
  stale_ids = {},
  resolved_locations = {},
}

local function report_storage_error(message)
  vim.notify(message, vim.log.levels.ERROR)
end

---@param view table
---@return integer
local function context_radius(view)
  return view.get_context_radius and view:get_context_radius() or 3
end

local pending_view_state = nil

---@param view table
---@param comments ReviewComment[]
---@param range string
local function apply_comments(view, comments, range)
  state.resolved_locations = {}
  local annotations = {}

  for _, comment in ipairs(comments) do
    table.insert(annotations, {
      id = comment.id,
      anchor = {
        file = comment.file,
        side = comment.side,
        line = comment.line,
        context = comment.context,
        context_start = comment.context_start,
      },
      text = comment.text,
    })
  end

  local result = view:sync_annotations(annotations, { radius = context_radius(view) })

  state.stale_ids = {}
  for _, id in ipairs(result.stale) do
    state.stale_ids[id] = true
  end

  for id, location in pairs(result.resolved or {}) do
    state.resolved_locations[id] = location
  end

  for id, moved in pairs(result.moved or {}) do
    storage.update_comment(range, id, {
      line = moved.location.line,
      context = moved.context,
      context_start = moved.context_start,
    })
  end
end

---@return string|nil
function M.get_current_range()
  return state.current_range
end

---@return string|nil
function M.get_commit_range()
  local view = viewer.current()
  return view and view:get_review_id() or nil
end

---@param range string
---@param view table|nil
---@return boolean
function M.load_session(range, view)
  local comments, err = storage.get_comments(range)
  if not comments then
    report_storage_error(err)
    return false
  end

  state.current_range = range
  state.current_view = view or viewer.current()
  if state.current_view then
    apply_comments(state.current_view, comments, range)
  end
  return true
end

---@param range string
---@param comment ReviewComment
---@return table|nil, string|nil
function M.add_comment(range, comment)
  local data, err = storage.add_comment(range, comment)
  if data then
    M.load_session(range)
  end
  return data, err
end

---@param range string
---@param id string
---@param updates table
---@return table|nil, string|nil
function M.update_comment(range, id, updates)
  local data, err = storage.update_comment(range, id, updates)
  if data then
    M.load_session(range)
  end
  return data, err
end

---@param range string
---@param id string
---@return table|nil, string|nil
function M.delete_comment(range, id)
  local data, err = storage.delete_comment(range, id)
  if data then
    M.load_session(range)
  end
  return data, err
end

---@param view table|nil
function M.on_view_opened(view)
  view = view or viewer.current()
  if not view then
    return
  end
  local range = view:get_review_id()
  if not range then
    return
  end
  if range == "loading" then
    return
  end
  if state.current_range and range ~= state.current_range then
    state.current_range = nil
    state.stale_ids = {}
  end
  local saved = pending_view_state
  pending_view_state = nil
  M.load_session(range, view)

  if saved and saved.review_id == range then
    view:restore_state(saved)
  end
end

---@return table|nil
function M.get_pending_view_state()
  return pending_view_state and vim.deepcopy(pending_view_state) or nil
end

function M.reset()
  state.current_range = nil
  state.current_view = nil
  state.stale_ids = {}
  state.resolved_locations = {}
  pending_view_state = nil
end

function M.on_view_closed(view)
  local saved = view and view:capture_state() or nil
  M.reset()
  pending_view_state = saved
end

---@param id string
---@return boolean
function M.is_stale(id)
  return state.stale_ids[id] == true
end

---@param comment ReviewComment
---@return table|nil
function M.resolve_comment(comment)
  if state.stale_ids[comment.id] then
    return nil
  end
  return state.resolved_locations[comment.id] or { file = comment.file, side = comment.side, line = comment.line }
end

return M

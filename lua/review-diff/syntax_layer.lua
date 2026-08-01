local syntax = require("review-diff.syntax")
local locations = require("review-diff.locations")

local M = {}

local syntax_ns = vim.api.nvim_create_namespace("review-diff-syntax")

---@return integer
function M.namespace()
  return syntax_ns
end

---@param options table
---@return boolean
local function disabled(options)
  local syntax_options = options.syntax
  return syntax_options == false or (type(syntax_options) == "table" and syntax_options.enabled == false)
end

---@param options table
---@return boolean
local function async_enabled(options)
  local syntax_options = options.syntax
  if type(syntax_options) ~= "table" then
    return false
  end
  return syntax_options.async ~= false
end

---@param file table
---@param side "left"|"right"
---@return string|nil path, string|nil text
local function syntax_value(file, side)
  local path = locations.path(file, side)
  local text = side == "left" and file.left_text or file.right_text
  return path, text
end

---Sets a single syntax highlight extmark for a span on a 1-based display row.
---@param bufnr integer
---@param row_index integer
---@param span table
local function apply_span(bufnr, row_index, span)
  local start_col = span.start_col
  local end_col = span.end_col
  if end_col > start_col then
    vim.api.nvim_buf_set_extmark(bufnr, syntax_ns, row_index - 1, start_col, {
      end_row = row_index - 1,
      end_col = end_col,
      hl_group = span.hl_group,
      hl_mode = "combine",
      priority = span.priority,
    })
  end
end

---Builds and caches syntax spans for a single file side.
---@param view table
---@param file table
---@param side "left"|"right"
local function ensure_cached(view, file, side)
  local path, text = syntax_value(file, side)
  if not path or not text or file.binary or file.too_large then
    return
  end
  view.syntax_cache[file.id] = view.syntax_cache[file.id] or {}
  local cached = view.syntax_cache[file.id][side]
  if not cached or cached.path ~= path or cached.text ~= text then
    view.syntax_cache[file.id][side] = {
      path = path,
      text = text,
      spans = syntax.collect(path, text, view.options.syntax),
    }
  end
end

---Applies cached syntax spans for a single file, both sides.
---@param view table
---@param file table
local function apply_file_syntax(view, file)
  if disabled(view.options) or file.binary or file.too_large then
    return
  end

  for _, side in ipairs({ "left", "right" }) do
    ensure_cached(view, file, side)
  end

  local cache = view.syntax_cache[file.id]
  local file_index = view.row_index and view.row_index[file.id]
  local range = view.file_row_ranges and view.file_row_ranges[file.id]
  if not cache or not file_index or not range then
    return
  end

  -- Clear namespace for this file's row range
  vim.api.nvim_buf_clear_namespace(view.left_buf, syntax_ns, range.start - 1, range.start - 1 + range.count)
  vim.api.nvim_buf_clear_namespace(view.right_buf, syntax_ns, range.start - 1, range.start - 1 + range.count)

  for _, side in ipairs({ "left", "right" }) do
    local bufnr = view[side .. "_buf"]
    local cached = cache[side]
    local side_index = file_index[side]
    if cached and side_index then
      for _, span in ipairs(cached.spans) do
        local relative = side_index[span.line]
        if relative then
          apply_span(bufnr, range.start + relative - 1, span)
        end
      end
    end
  end
end

---Returns list of files sorted by visibility: visible files first, then the rest.
---@param view table
---@return table[]
local function files_by_priority(view)
  local visible_ids = {}
  for _, side in ipairs({ "left", "right" }) do
    local win = view[side .. "_win"]
    if vim.api.nvim_win_is_valid(win) then
      local top = vim.fn.line("w0", win)
      local bot = vim.fn.line("w$", win)
      for _, file in ipairs(view.files) do
        local range = view.file_row_ranges and view.file_row_ranges[file.id]
        if range then
          local file_top = range.start
          local file_bot = range.start + range.count - 1
          if file_bot >= top and file_top <= bot then
            visible_ids[file.id] = true
          end
        end
      end
    end
  end

  local visible = {}
  local rest = {}
  for _, file in ipairs(view.files) do
    if visible_ids[file.id] then
      table.insert(visible, file)
    else
      table.insert(rest, file)
    end
  end
  for _, file in ipairs(rest) do
    table.insert(visible, file)
  end
  return visible
end

---Schedules async syntax highlighting queue for all files.
---Each file is processed in a separate vim.schedule tick.
---@param view table
---@param generation integer
local function schedule_queue(view, generation)
  local ordered = files_by_priority(view)
  local index = 1

  local function process_next()
    if view.closed or view._syntax_generation ~= generation then
      return
    end
    if index > #ordered then
      return
    end
    local file = ordered[index]
    index = index + 1
    apply_file_syntax(view, file)
    vim.schedule(process_next)
  end

  vim.schedule(process_next)
end

---Full re-apply of Tree-sitter syntax across every file and both sides.
---When async is enabled, clears extmarks immediately and schedules per-file
---highlighting. When async is disabled (or flush mode), runs synchronously.
---@param view table
function M.apply(view)
  for _, side in ipairs({ "left", "right" }) do
    vim.api.nvim_buf_clear_namespace(view[side .. "_buf"], syntax_ns, 0, -1)
  end

  if disabled(view.options) then
    return
  end

  -- Bump generation to invalidate any in-flight queue
  view._syntax_generation = (view._syntax_generation or 0) + 1
  local generation = view._syntax_generation

  if async_enabled(view.options) then
    schedule_queue(view, generation)
  else
    -- Synchronous path (async=false or flush mode)
    for _, file in ipairs(view.files) do
      if generation ~= view._syntax_generation then
        return
      end
      apply_file_syntax(view, file)
    end
  end
end

---Re-applies cached syntax spans for exactly one file within its buffer range,
---leaving every other file's syntax extmarks untouched.
---@param view table
---@param file table
---@param range table {start, count}
function M.apply_for_file(view, file, range)
  vim.api.nvim_buf_clear_namespace(view.left_buf, syntax_ns, range.start - 1, range.start - 1 + range.count)
  vim.api.nvim_buf_clear_namespace(view.right_buf, syntax_ns, range.start - 1, range.start - 1 + range.count)

  if disabled(view.options) or file.binary or file.too_large then
    return
  end

  local cache = view.syntax_cache[file.id]
  local file_index = view.row_index[file.id]
  if not cache or not file_index then
    return
  end

  for _, side in ipairs({ "left", "right" }) do
    local bufnr = view[side .. "_buf"]
    local cached = cache[side]
    local side_index = file_index[side]
    if cached and side_index then
      for _, span in ipairs(cached.spans) do
        local relative = side_index[span.line]
        if relative then
          apply_span(bufnr, range.start + relative - 1, span)
        end
      end
    end
  end
end

---Synchronously drains the entire async syntax queue for testing or flush use.
---Processes all files in order, bypassing the async schedule.
---@param view table
function M.flush(view)
  if disabled(view.options) then
    return
  end
  -- Bump generation to cancel any in-flight scheduled queue
  view._syntax_generation = (view._syntax_generation or 0) + 1

  -- Clear all syntax extmarks
  for _, side in ipairs({ "left", "right" }) do
    vim.api.nvim_buf_clear_namespace(view[side .. "_buf"], syntax_ns, 0, -1)
  end

  -- Apply all files synchronously
  for _, file in ipairs(view.files) do
    apply_file_syntax(view, file)
  end
end

---Reprioritizes the async queue by bumping visible files to the front.
---Safe to call at any time (e.g. on WinScrolled); only has effect when
---an async queue is in flight.
---@param view table
function M.reprioritize(view)
  if disabled(view.options) or not async_enabled(view.options) then
    return
  end
  if not view._syntax_generation then
    return
  end
  -- Restart the queue with the current priority order, preserving generation
  -- so the old queue's ticks become stale automatically on the next bump.
  view._syntax_generation = (view._syntax_generation or 0) + 1
  local generation = view._syntax_generation
  schedule_queue(view, generation)
end

return M

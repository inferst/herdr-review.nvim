local model = require("review-diff.model")
local locations = require("review-diff.locations")

local M = {}

---Identifies a context fold by its file and source-row range.
---@param file_id string
---@param first_row integer
---@param last_row integer
---@return string
function M.key(file_id, first_row, last_row)
  return string.format("%s:%d:%d", file_id, first_row, last_row)
end

---Expands a file and, when given, the context fold containing a source row.
---@param view table
---@param file table|nil
---@param source_index integer|nil
---@return boolean
function M.expand_source_row(view, file, source_index)
  if not file then
    return false
  end
  view.state.collapsed_files[file.id] = false
  if not source_index then
    return true
  end
  for _, row in ipairs(model.visible_rows(file, view.state.context_lines)) do
    if row.kind == "fold" and source_index >= row.first_row and source_index <= row.last_row then
      view.state.expanded_folds[M.key(file.id, row.first_row, row.last_row)] = true
      break
    end
  end
  return true
end

---Expands whichever fold hides the source line for a location.
---@param view table
---@param location table
---@return table|nil file
function M.expand_location(view, location)
  local file = locations.file_for(view.files, location)
  if not file then
    return nil
  end
  local side_line = location.side .. "_line"
  local source_index
  for index, row in ipairs(file.rows) do
    if row[side_line] == location.line then
      source_index = index
      break
    end
  end
  M.expand_source_row(view, file, source_index)
  return file
end

---@param view table
function M.toggle_file_at_cursor(view)
  local cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
  local row = view.display_rows[cursor[1]]
  if not row or not row.file_id then
    return
  end
  local file_id = row.file_id
  view.state.collapsed_files[file_id] = not view.state.collapsed_files[file_id]
  view:render_file(row.file)
  if view.state.collapsed_files[file_id] then
    for index, display_row in ipairs(view.display_rows) do
      if display_row.file_id == file_id then
        view:set_cursor_row(index)
        break
      end
    end
  end
end

---@param view table
function M.toggle_fold_at_cursor(view)
  local cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
  local row = view.display_rows[cursor[1]]
  if not row then
    return
  end
  if row.display_kind == "file_header" then
    M.toggle_file_at_cursor(view)
  elseif row.display_kind == "fold" then
    local file_id = row.file_id
    local target_first = row.fold.first_row
    local target_last = row.fold.last_row
    local key = M.key(file_id, target_first, target_last)
    local was_expanded = view.state.expanded_folds[key]
    view.state.expanded_folds[key] = not was_expanded
    view:render_file(row.file)
    if was_expanded then
      for index, display_row in ipairs(view.display_rows) do
        if
          display_row.display_kind == "fold"
          and display_row.file_id == file_id
          and display_row.fold.first_row == target_first
          and display_row.fold.last_row == target_last
        then
          view:set_cursor_row(index)
          break
        end
      end
    end
  end
end

---@param view table
function M.expand_all(view)
  for _, file in ipairs(view.files) do
    view.state.collapsed_files[file.id] = false
  end
  view.state.expanded_folds = {}
  for _, file in ipairs(view.files) do
    for _, row in ipairs(model.visible_rows(file, view.state.context_lines)) do
      if row.kind == "fold" then
        view.state.expanded_folds[M.key(file.id, row.first_row, row.last_row)] = true
      end
    end
  end
  view:render()
end

---@param view table
function M.collapse_all(view)
  for _, file in ipairs(view.files) do
    view.state.collapsed_files[file.id] = true
  end
  view.state.expanded_folds = {}
  view:render()
end

---@param view table
function M.toggle_all(view)
  local all_collapsed = true
  for _, file in ipairs(view.files) do
    if not view.state.collapsed_files[file.id] then
      all_collapsed = false
      break
    end
  end
  for _, file in ipairs(view.files) do
    view.state.collapsed_files[file.id] = not all_collapsed
  end
  view:render()
end

return M

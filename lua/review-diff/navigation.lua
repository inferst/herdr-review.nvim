local M = {}

local layout = require("review-diff.layout")

local function move_to_rows(view, predicate, direction)
  local cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
  local candidates = {}
  for index, row in ipairs(view.display_rows) do
    if predicate(row) then
      table.insert(candidates, index)
    end
  end
  if #candidates == 0 then
    return
  end
  if direction > 0 then
    for _, index in ipairs(candidates) do
      if index > cursor[1] then
        view:set_cursor_row(index)
        return
      end
    end
    view:set_cursor_row(candidates[1])
  else
    for index = #candidates, 1, -1 do
      if candidates[index] < cursor[1] then
        view:set_cursor_row(candidates[index])
        return
      end
    end
    view:set_cursor_row(candidates[#candidates])
  end
end

local function source_index_for_display_row(row)
  if not row or row.display_kind ~= "line" or not row.file then
    return nil
  end
  for index, source_row in ipairs(row.file.rows or {}) do
    if source_row == row.source_row then
      return index
    end
  end
  return nil
end

local function collect_hunk_targets(view)
  local targets = {}
  for _, file in ipairs(view.files) do
    for _, hunk in ipairs(file.hunks or {}) do
      table.insert(targets, {
        file = file,
        hunk = hunk,
        source_index = hunk.first_row,
      })
    end
  end
  return targets
end

local function hunk_contains_source_index(hunk, source_index)
  return source_index and source_index >= hunk.first_row and source_index <= hunk.last_row
end

local function current_hunk_target_index(view, targets)
  local cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
  local row = view.display_rows[cursor[1]]
  local source_index = source_index_for_display_row(row)
  if not source_index then
    return nil
  end
  for index, target in ipairs(targets) do
    if target.file == row.file and hunk_contains_source_index(target.hunk, source_index) then
      return index
    end
  end
  return nil
end

local function display_row_for_source_index(view, file, source_index)
  for index, row in ipairs(view.display_rows) do
    if row.display_kind == "line" and row.file == file and row.source_row == file.rows[source_index] then
      return index
    end
  end
  return nil
end

local function file_header_row(view, file)
  for index, row in ipairs(view.display_rows) do
    if row.display_kind == "file_header" and row.file == file then
      return index
    end
  end
  return nil
end

local function target_anchor_row(view, target)
  local exact = display_row_for_source_index(view, target.file, target.source_index)
  if exact then
    return exact
  end

  for index, row in ipairs(view.display_rows) do
    if
      row.display_kind == "fold"
      and row.file == target.file
      and target.source_index >= row.fold.first_row
      and target.source_index <= row.fold.last_row
    then
      return index
    end
  end

  return file_header_row(view, target.file)
end

local function cursor_on_collapsed_file_header(view, cursor_row, target)
  local row = view.display_rows[cursor_row]
  return row and row.display_kind == "file_header" and row.file == target.file and row.collapsed == true
end

local function next_hunk_target_index(view, targets, direction)
  local current_index = current_hunk_target_index(view, targets)
  if current_index then
    if direction > 0 then
      return current_index == #targets and 1 or current_index + 1
    end
    return current_index == 1 and #targets or current_index - 1
  end

  local cursor_row = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1]
  if direction > 0 then
    for index, target in ipairs(targets) do
      local anchor = target_anchor_row(view, target)
      if anchor and (anchor > cursor_row or cursor_on_collapsed_file_header(view, cursor_row, target)) then
        return index
      end
    end
    return 1
  end

  for index = #targets, 1, -1 do
    local anchor = target_anchor_row(view, targets[index])
    if anchor and anchor < cursor_row then
      return index
    end
  end
  return #targets
end

function M.set_cursor_row(view, row_index, col)
  if #view.display_rows == 0 then
    return
  end
  row_index = math.max(1, math.min(#view.display_rows, row_index))
  local current_win = vim.api.nvim_get_current_win()
  local current_side = view.win_sides[current_win]
  if current_side then
    view.last_side = current_side
  end
  local active_side = view.last_side
  for _, side in ipairs({ "left", "right" }) do
    local win = view[side .. "_win"]
    if layout.valid_window(win) then
      local win_col = (col and col > 0 and side == active_side) and col or 0
      vim.api.nvim_win_set_cursor(win, { row_index, win_col })
    end
  end
  view:update_cursorline()
end

function M.move_file(view, direction)
  move_to_rows(view, function(row)
    return row.display_kind == "file_header"
  end, direction)
end

function M.move_hunk(view, direction)
  local targets = collect_hunk_targets(view)
  if #targets == 0 then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local side = view.win_sides[current_win]
  local target = targets[next_hunk_target_index(view, targets, direction)]
  if not target then
    return
  end

  local expanded = view:expand_source_row(target.file, target.source_index)
  if expanded then
    view:render_file(target.file)
  end

  local row_index = display_row_for_source_index(view, target.file, target.source_index)
  if row_index then
    if side and layout.valid_window(view[side .. "_win"]) then
      vim.api.nvim_set_current_win(view[side .. "_win"])
    end
    view:set_cursor_row(row_index)
  end
end

return M

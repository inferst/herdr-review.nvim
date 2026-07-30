local layout = require("review-diff.layout")
local locations = require("review-diff.locations")

local M = {}

local function cursor_location_for_window(view, win)
  if not layout.valid_window(win) then
    return nil
  end
  local side = view.win_sides[win]
  if not side then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = view.display_rows[cursor[1]]
  if not row or row.display_kind ~= "line" then
    return nil
  end
  local line = row.source_row[side .. "_line"]
  local path = locations.path(row.file, side)
  if not line or not path then
    return nil
  end
  return { file = locations.normalize(path), side = side, line = line, col = cursor[2] }
end

local function cursor_anchor_for_window(view, win)
  if not layout.valid_window(win) then
    return nil
  end
  local side = view.win_sides[win]
  if not side then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = view.display_rows[cursor[1]]
  if not row or not row.file then
    return nil
  end

  local path = locations.path(row.file, side)
  if not path then
    return nil
  end
  local location = { file = locations.normalize(path), side = side }
  if row.display_kind == "line" then
    location.line = row.source_row[side .. "_line"]
  elseif row.display_kind == "fold" then
    local source_row = row.file.rows[row.fold.first_row]
    location.line = source_row and source_row[side .. "_line"] or nil
  end
  return location
end

local function fold_contains_line(row, side, line)
  if not row.fold or not line then
    return false
  end
  for source_index = row.fold.first_row, row.fold.last_row do
    local source_row = row.file.rows[source_index]
    if source_row and source_row[side .. "_line"] == line then
      return true
    end
  end
  return false
end

function M.cursor_location(view, win)
  return cursor_location_for_window(view, win)
end

function M.capture(view)
  local review_id = view:get_review_id()
  if not review_id then
    return nil
  end

  local snapshot = {
    review_id = review_id,
    collapsed_files = vim.deepcopy(view.state.collapsed_files),
    expanded_folds = vim.deepcopy(view.state.expanded_folds),
  }

  local current_win = vim.api.nvim_get_current_win()
  local current_side = view.win_sides[current_win]
  local side = current_side or view.last_side
  if current_side then
    view.last_side = current_side
  end
  local win = side and view[side .. "_win"] or nil
  snapshot.cursor = cursor_location_for_window(view, win) or cursor_anchor_for_window(view, win)
  return snapshot
end

function M.restore(view, snapshot)
  if not snapshot or snapshot.review_id ~= view:get_review_id() then
    return
  end

  for id, collapsed in pairs(snapshot.collapsed_files or {}) do
    if view.state.collapsed_files[id] ~= nil then
      view.state.collapsed_files[id] = collapsed
    end
  end
  view.state.expanded_folds = vim.deepcopy(snapshot.expanded_folds or {})

  local cursor = snapshot.cursor
  local cursor_side = cursor and (cursor.side == "old" or cursor.side == "new") and cursor.side or nil
  local cursor_file = cursor_side and locations.file_for(view.files, cursor) or nil
  if cursor_file and cursor.line then
    view.state.collapsed_files[cursor_file.id] = false
  end

  view:render()

  if not cursor_file then
    return
  end

  local row_index
  local header_index
  for index, row in ipairs(view.display_rows) do
    if row.file_id == cursor_file.id then
      if row.display_kind == "file_header" then
        header_index = index
      elseif cursor.line and row.display_kind == "fold" and fold_contains_line(row, cursor_side, cursor.line) then
        row_index = index
        break
      elseif cursor.line and row.display_kind == "line" then
        local side_line = row.source_row[cursor_side .. "_line"]
        if side_line == cursor.line then
          row_index = index
          break
        end
      elseif not cursor.line and row.display_kind == "file_header" then
        row_index = index
        break
      end
    end
  end

  row_index = row_index or header_index
  if row_index then
    view.last_side = cursor_side
    view:set_cursor_row(row_index, cursor.col)
    view.last_side = cursor_side
  end
end

return M

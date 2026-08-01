local render = require("review-diff.render")
local syntax_layer = require("review-diff.syntax_layer")

local M = {}

local render_ns = vim.api.nvim_create_namespace("review-diff-render")

---Builds a relative line index for one file's display rows, mapping each
---side's source line number to its 1-based offset within `rows`.
---@param rows table[]
---@return table
function M.build_file_index(rows)
  local index = { left = {}, right = {} }
  for offset, row in ipairs(rows) do
    if row.display_kind == "line" then
      local source_row = row.source_row
      if source_row.left_line then
        index.left[source_row.left_line] = offset
      end
      if source_row.right_line then
        index.right[source_row.right_line] = offset
      end
    end
  end
  return index
end

---Rebuilds `view.file_row_ranges` (absolute buffer position per file) and
---`view.row_index` (relative line index per file) from `view.display_rows`.
---Must run after every full render, before `location_row()` lookups.
---@param view table
function M.reindex(view)
  local rows = view.display_rows
  local ranges = {}
  local indices = {}
  local i, n = 1, #rows
  while i <= n do
    local file_id = rows[i].file_id
    if not file_id then
      i = i + 1
    else
      local start = i
      while i <= n and rows[i].file_id == file_id do
        i = i + 1
      end
      local slice = {}
      for j = start, i - 1 do
        table.insert(slice, rows[j])
      end
      ranges[file_id] = { start = start, count = i - start }
      indices[file_id] = M.build_file_index(slice)
    end
  end
  view.file_row_ranges = ranges
  view.row_index = indices
end

---Writes `rows` into one side's buffer at `[start_row0, end_row0)` (0-based,
---`end_row0 = -1` meaning "to the end of the buffer"), replacing whatever was
---there before, and re-applies the base highlight extmarks for those rows.
---@param view table
---@param side "left"|"right"
---@param rows table[]
---@param start_row0 integer
---@param end_row0 integer
function M.write_rows(view, side, rows, start_row0, end_row0)
  local bufnr = view[side .. "_buf"]
  local lines = {}
  for _, row in ipairs(rows) do
    table.insert(lines, render.text(row, side))
  end

  vim.api.nvim_buf_clear_namespace(bufnr, render_ns, start_row0, end_row0)

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, start_row0, end_row0, false, lines)
  vim.bo[bufnr].modifiable = false

  for offset, row in ipairs(rows) do
    local row0 = start_row0 + offset - 1
    local line_hl, inline = render.highlight(row, side, view.options)
    if line_hl then
      local col_start = 0
      if line_hl == "ReviewDiffAdd" or line_hl == "ReviewDiffDelete" or line_hl == "ReviewDiffChange" then
        vim.api.nvim_buf_set_extmark(bufnr, render_ns, row0, col_start, {
          end_row = row0 + 1,
          end_col = 0,
          hl_group = line_hl,
          hl_eol = true,
          priority = 50,
        })
      else
        vim.api.nvim_buf_set_extmark(bufnr, render_ns, row0, col_start, {
          end_row = row0,
          end_col = #lines[offset],
          hl_group = line_hl,
          priority = 50,
        })
      end
    end
    if inline then
      local items = inline.hl_group and { inline } or inline
      for _, item in ipairs(items) do
        if item.finish > item.start then
          vim.api.nvim_buf_set_extmark(bufnr, render_ns, row0, item.start, {
            end_row = row0,
            end_col = item.finish,
            hl_group = item.hl_group,
            priority = 80,
          })
        end
      end
    end
  end
end

---Re-renders exactly one file's rows in place: buffer lines, base highlight
---extmarks, and cached syntax extmarks. Every other file's buffer lines and
---extmarks are left untouched, and their absolute positions are shifted
---cheaply if this file's row count changed. Annotations and the cursorline
---marker stay global since their cost does not scale with diff size.
---@param view table
---@param file table
function M.render_file(view, file)
  local range = view.file_row_ranges and view.file_row_ranges[file.id]
  if not range then
    view:render()
    return
  end

  local new_rows = render.display_rows({ file }, view.state)
  local old_count = range.count
  local new_count = #new_rows
  local delta = new_count - old_count

  for _ = 1, old_count do
    table.remove(view.display_rows, range.start)
  end
  for offset, row in ipairs(new_rows) do
    table.insert(view.display_rows, range.start + offset - 1, row)
  end

  view.rendering = true
  for _, side in ipairs({ "left", "right" }) do
    M.write_rows(view, side, new_rows, range.start - 1, range.start - 1 + old_count)
  end
  view.rendering = false

  range.count = new_count
  view.row_index[file.id] = M.build_file_index(new_rows)

  if delta ~= 0 then
    for other_id, other_range in pairs(view.file_row_ranges) do
      if other_id ~= file.id and other_range.start > range.start then
        other_range.start = other_range.start + delta
      end
    end
  end

  syntax_layer.apply_for_file(view, file, range)
  view:apply_annotations()
  view:update_cursorline()
  view:emit("rendered")
end

return M

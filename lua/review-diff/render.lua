local model = require("review-diff.model")

local M = {}

local STATUS_LABELS = {
  added = "A",
  copied = "C",
  deleted = "D",
  modified = "M",
  renamed = "R",
  binary = "B",
}

local function side_path(file, side)
  return side == "old" and file.old_path or file.new_path
end

local function path_label(file, side)
  return side_path(file, side) or "—"
end

local function fold_key(file, row)
  return string.format("%s:%d:%d", file.id, row.first_row, row.last_row)
end

---@param files table[]
---@param state table
---@return table[]
function M.display_rows(files, state)
  local rows = {}
  for _, file in ipairs(files) do
    table.insert(rows, {
      display_kind = "file_header",
      file = file,
      file_id = file.id,
      collapsed = state.collapsed_files[file.id] == true,
    })

    if not state.collapsed_files[file.id] then
      if file.binary or file.too_large then
        table.insert(rows, {
          display_kind = "metadata",
          file = file,
          file_id = file.id,
          text = file.binary and "binary file changed" or "file is too large to diff",
        })
      else
        local visible_rows = model.visible_rows(file, state.context_lines)
        for _, row in ipairs(visible_rows) do
          if row.kind == "fold" and state.expanded_folds[fold_key(file, row)] then
            for source_index = row.first_row, row.last_row do
              table.insert(rows, {
                display_kind = "line",
                file = file,
                file_id = file.id,
                source_row = file.rows[source_index],
              })
            end
          elseif row.kind == "fold" then
            table.insert(rows, {
              display_kind = "fold",
              file = file,
              file_id = file.id,
              fold = row,
              expanded = false,
            })
          else
            table.insert(rows, {
              display_kind = "line",
              file = file,
              file_id = file.id,
              source_row = row,
            })
          end
        end
      end
    end
  end

  if #rows == 0 then
    table.insert(rows, { display_kind = "empty", text = state.empty_text or "No changes" })
  end
  return rows
end

---@param row table
---@param side "old"|"new"
---@return string
function M.text(row, side)
  if row.display_kind == "empty" then
    return "  " .. row.text
  end
  if row.display_kind == "file_header" then
    local marker = row.collapsed and "▶" or "▼"
    local status = STATUS_LABELS[row.file.status] or "M"
    return string.format("%s %s %s", marker, status, path_label(row.file, side))
  end
  if row.display_kind == "metadata" then
    return "  " .. row.text
  end
  if row.display_kind == "fold" then
    return string.format("  ⋯ %d unchanged lines ⋯", row.fold.count)
  end

  local source_row = row.source_row
  local line = side == "old" and source_row.old_line or source_row.new_line
  local text = side == "old" and source_row.old_text or source_row.new_text
  local prefix = line and string.format("%5d │ ", line) or "      │ "
  return prefix .. (text or "")
end

---@param row table
---@param side "old"|"new"
---@return string|nil, table|nil
function M.highlight(row, side)
  if row.display_kind == "file_header" then
    return "ReviewDiffFileHeader", nil
  end
  if row.display_kind == "metadata" then
    return "ReviewDiffMetadata", nil
  end
  if row.display_kind == "fold" then
    return "ReviewDiffFold", nil
  end
  if row.display_kind ~= "line" then
    return nil, nil
  end

  local source_row = row.source_row
  local line_text = side == "old" and source_row.old_text or source_row.new_text
  local line_hl
  if source_row.kind == "add" and side == "new" then
    line_hl = "ReviewDiffAdd"
  elseif source_row.kind == "delete" and side == "old" then
    line_hl = "ReviewDiffDelete"
  elseif source_row.kind == "change" then
    line_hl = "ReviewDiffChange"
  end

  if source_row.kind ~= "change" or not line_text then
    return line_hl, nil
  end

  local old_text = source_row.old_text or ""
  local new_text = source_row.new_text or ""
  local range = model.inline_ranges(old_text, new_text)
  if not range then
    return line_hl, nil
  end

  local line = side == "old" and source_row.old_line or source_row.new_line
  local prefix_width = line and #string.format("%5d │ ", line) or #"      │ "
  if side == "old" then
    return line_hl, { start = prefix_width + range.old_start, finish = prefix_width + range.old_end }
  end
  return line_hl, { start = prefix_width + range.new_start, finish = prefix_width + range.new_end }
end

return M

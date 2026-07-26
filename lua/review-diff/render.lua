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
  if side == "old" then
    return file.old_path
  end
  return file.new_path
end

local function path_label(file, side)
  return side_path(file, side) or "—"
end

local function source_line(row, side)
  if side == "old" then
    return row.source_row.old_line
  end
  return row.source_row.new_line
end

---@param row table
---@param side "old"|"new"
---@return integer
function M.source_prefix_width(row, side)
  local line = source_line(row, side)
  return line and #string.format("%5d │ ", line) or #"      │ "
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
---@param width integer|nil
---@return string
function M.text(row, side, width)
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
  local line
  local text
  if side == "old" then
    line = source_row.old_line
    text = source_row.old_text
  else
    line = source_row.new_line
    text = source_row.new_text
  end
  local prefix = line and string.format("%5d │ ", line) or "      │ "
  if not line and width then
    local remaining = math.max(0, width - vim.fn.strdisplaywidth(prefix))
    return prefix .. string.rep(" ", remaining)
  end
  return prefix .. (text or "")
end

---@param row table
---@param side "old"|"new"
---@param opts table|nil
---@return string|nil, table|nil
function M.highlight(row, side, opts)
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
  local line_text
  if side == "old" then
    line_text = source_row.old_text
  else
    line_text = source_row.new_text
  end
  local line_hl
  if source_row.kind == "add" then
    line_hl = side == "new" and "ReviewDiffAdd" or "ReviewDiffChange"
  elseif source_row.kind == "delete" then
    line_hl = side == "old" and "ReviewDiffDelete" or "ReviewDiffChange"
  elseif source_row.kind == "change" then
    line_hl = side == "old" and "ReviewDiffDelete" or "ReviewDiffAdd"
  end

  if source_row.kind ~= "change" or not line_text then
    return line_hl, nil
  end

  if not (opts and opts.intra_line) then
    return line_hl, nil
  end

  local old_text = source_row.old_text or ""
  local new_text = source_row.new_text or ""
  local range = model.inline_ranges(old_text, new_text)
  if not range then
    return line_hl, nil
  end

  local prefix_width = M.source_prefix_width(row, side)
  if side == "old" then
    return line_hl, { start = prefix_width + range.old_start, finish = prefix_width + range.old_end }
  end
  return line_hl, { start = prefix_width + range.new_start, finish = prefix_width + range.new_end }
end

return M

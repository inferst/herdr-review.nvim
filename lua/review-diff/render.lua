local model = require("review-diff.model")

local M = {}

local function wrap_text(text, max_width)
  if max_width < 1 or not text or text == "" then
    return { "" }
  end
  local lines = {}
  for word in text:gmatch("%S+") do
    local current = lines[#lines]
    if not current then
      if vim.fn.strdisplaywidth(word) > max_width then
        table.insert(lines, word)
      else
        table.insert(lines, word)
      end
    else
      local candidate = current .. " " .. word
      if vim.fn.strdisplaywidth(candidate) <= max_width then
        lines[#lines] = candidate
      else
        table.insert(lines, word)
      end
    end
  end
  if #lines == 0 then
    lines = { "" }
  end
  return lines
end

---@param text string
---@param win_width integer
---@return table[]
function M.annotation_lines(text, win_width)
  local width = math.max(20, win_width)

  local top = {
    { "┌─ ", "ReviewDiffCommentBorder" },
    { "Comment", "ReviewDiffCommentTitle" },
    { " " .. string.rep("─", math.max(0, width - 12)) .. "┐", "ReviewDiffCommentBorder" },
  }

  local content_w = width - 4
  local wrapped = wrap_text(text, content_w)
  local content = {}
  for _, line in ipairs(wrapped) do
    local line_w = vim.fn.strdisplaywidth(line)
    local pad = math.max(0, content_w - line_w)
    table.insert(content, {
      { "│ ", "ReviewDiffCommentBorder" },
      { line .. string.rep(" ", pad), "ReviewDiffCommentText" },
      { " │", "ReviewDiffCommentBorder" },
    })
  end

  local bottom = {
    { "└", "ReviewDiffCommentBorder" },
    { string.rep("─", math.max(0, width - 2)) .. "┘", "ReviewDiffCommentBorder" },
  }

  local result = { top }
  for _, c in ipairs(content) do
    table.insert(result, c)
  end
  table.insert(result, bottom)
  return result
end

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
  if row.display_kind == "hint" then
    return row.hint_text or ""
  end
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
  local text
  if side == "old" then
    text = source_row.old_text
  else
    text = source_row.new_text
  end
  return text or ""
end

---@param row table
---@param side "old"|"new"
---@param opts table|nil
---@return string|nil, table|nil
function M.highlight(row, side, opts)
  if row.display_kind == "hint" then
    local hint_text = row.hint_text or ""
    if hint_text == "" then
      return nil, nil
    end
    return "ReviewDiffHint", nil
  end
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

  local inline_hl
  if side == "old" then
    inline_hl = "ReviewDiffDeleteIntra"
  else
    inline_hl = "ReviewDiffAddIntra"
  end

  if side == "old" then
    return line_hl,
      {
        start = range.old_start,
        finish = range.old_end,
        hl_group = inline_hl,
        line_text = line_text,
      }
  end
  return line_hl,
    {
      start = range.new_start,
      finish = range.new_end,
      hl_group = inline_hl,
      line_text = line_text,
    }
end

---@param hint_text string
---@param width integer
---@return string[]
function M.wrap_hint_text(hint_text, width)
  if not hint_text or hint_text == "" then
    return {}
  end
  local parts = vim.split(hint_text, " | ", { plain = true })
  if #parts == 0 then
    return {}
  end
  local prefix = parts[1]
  local segments = {}
  for i = 2, #parts do
    segments[#segments + 1] = parts[i]
  end
  local lines = {}
  local current = prefix
  for _, seg in ipairs(segments) do
    local candidate = current .. " | " .. seg
    if vim.fn.strdisplaywidth(candidate) <= width then
      current = candidate
    else
      lines[#lines + 1] = current
      current = "  " .. seg
    end
  end
  lines[#lines + 1] = current
  return lines
end

return M

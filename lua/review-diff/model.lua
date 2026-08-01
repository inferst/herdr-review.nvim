local M = {}

---@param left_text string
---@param right_text string
---@return table|nil
function M.inline_ranges(left_text, right_text)
  if left_text == right_text then
    return nil
  end

  local left_length = vim.fn.strchars(left_text)
  local right_length = vim.fn.strchars(right_text)
  local prefix = 0
  while prefix < left_length and prefix < right_length do
    if vim.fn.strcharpart(left_text, prefix, 1) ~= vim.fn.strcharpart(right_text, prefix, 1) then
      break
    end
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < left_length - prefix and suffix < right_length - prefix do
    local left_char = vim.fn.strcharpart(left_text, left_length - suffix - 1, 1)
    local right_char = vim.fn.strcharpart(right_text, right_length - suffix - 1, 1)
    if left_char ~= right_char then
      break
    end
    suffix = suffix + 1
  end

  return {
    left_start = prefix == 0 and 0 or #vim.fn.strcharpart(left_text, 0, prefix),
    left_end = suffix == 0 and #left_text or #vim.fn.strcharpart(left_text, 0, left_length - suffix),
    right_start = prefix == 0 and 0 or #vim.fn.strcharpart(right_text, 0, prefix),
    right_end = suffix == 0 and #right_text or #vim.fn.strcharpart(right_text, 0, right_length - suffix),
  }
end

local function split_lines(text)
  if not text or text == "" then
    return {}
  end

  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function path_for_sort(file)
  return file.right_path or file.left_path or ""
end

local function append_context_rows(rows, left_lines, right_lines, left_start, right_start, left_stop, right_stop)
  while left_start < left_stop and right_start < right_stop do
    table.insert(rows, {
      kind = "context",
      left_line = left_start,
      right_line = right_start,
      left_text = left_lines[left_start],
      right_text = right_lines[right_start],
    })
    left_start = left_start + 1
    right_start = right_start + 1
  end
  return left_start, right_start
end

local function hunk_line_start(start, count)
  -- An indices hunk points at the first changed line when count is nonzero.
  -- With an empty side, start is the number of unchanged lines before the
  -- change, so the next source line is one position later.
  return count == 0 and start + 1 or start
end

local function source_range(start, count)
  if count == 0 then
    return nil, nil
  end
  return start, start + count - 1
end

local function hunk_metadata(id, first_row, last_row, hunk)
  local left_count = hunk[2]
  local right_count = hunk[4]
  local left_start_line = hunk_line_start(hunk[1], left_count)
  local right_start_line = hunk_line_start(hunk[3], right_count)
  local left_start, left_end = source_range(left_start_line, left_count)
  local right_start, right_end = source_range(right_start_line, right_count)

  return {
    id = id,
    first_row = first_row,
    last_row = last_row,
    left_start = left_start,
    left_end = left_end,
    right_start = right_start,
    right_end = right_end,
  }
end

local function append_change_rows(rows, left_lines, right_lines, hunk)
  local left_count = hunk[2]
  local right_count = hunk[4]
  local left_start = hunk_line_start(hunk[1], left_count)
  local right_start = hunk_line_start(hunk[3], right_count)
  local count = math.max(left_count, right_count)

  for offset = 0, count - 1 do
    local left_index = offset < left_count and left_start + offset or nil
    local right_index = offset < right_count and right_start + offset or nil
    local left_text = left_index and left_lines[left_index] or nil
    local right_text = right_index and right_lines[right_index] or nil
    local kind = left_index and right_index and (left_text == right_text and "context" or "change")
      or (left_index and "delete" or "add")

    table.insert(rows, {
      kind = kind,
      left_line = left_index,
      right_line = right_index,
      left_text = left_text,
      right_text = right_text,
    })
  end

  return left_start + left_count, right_start + right_count
end

---@param file table
---@param opts table|nil
---@return table
function M.build_file(file, opts)
  opts = opts or {}
  local left_lines = split_lines(file.left_text)
  local right_lines = split_lines(file.right_text)
  local result = vim.deepcopy(file)
  result.id = result.id or table.concat({ result.left_path or "", result.right_path or "" }, "\0")
  result.left_lines = left_lines
  result.right_lines = right_lines
  result.rows = {}
  result.hunks = {}

  if result.binary or result.too_large then
    return result
  end

  local diff_opts = { result_type = "indices", algorithm = opts.algorithm or "histogram" }
  if opts.ignore_whitespace then
    diff_opts.ignore_whitespace = true
  end
  local diff = vim.text and vim.text.diff or vim.diff
  local hunks = diff(table.concat(left_lines, "\n"), table.concat(right_lines, "\n"), diff_opts)
  local left_cursor, right_cursor = 1, 1
  local added, removed = 0, 0

  for _, hunk in ipairs(hunks) do
    local left_start = hunk_line_start(hunk[1], hunk[2])
    local right_start = hunk_line_start(hunk[3], hunk[4])
    append_context_rows(result.rows, left_lines, right_lines, left_cursor, right_cursor, left_start, right_start)

    local first_row = #result.rows + 1
    left_cursor, right_cursor = append_change_rows(result.rows, left_lines, right_lines, hunk)
    local last_row = #result.rows

    table.insert(result.hunks, hunk_metadata(#result.hunks + 1, first_row, last_row, hunk))
    added = added + hunk[4]
    removed = removed + hunk[2]
  end

  append_context_rows(
    result.rows,
    left_lines,
    right_lines,
    left_cursor,
    right_cursor,
    #left_lines + 1,
    #right_lines + 1
  )
  result.added_lines = added
  result.removed_lines = removed

  return result
end

---@param files table[]
---@param opts table|nil
---@return table
function M.build(files, opts)
  local result = { files = {} }
  for _, file in ipairs(files or {}) do
    table.insert(result.files, M.build_file(file, opts))
  end

  table.sort(result.files, function(left, right)
    return path_for_sort(left) < path_for_sort(right)
  end)
  return result
end

---@param file table
---@param context_lines integer
---@return table[]
function M.visible_rows(file, context_lines)
  context_lines = context_lines or 3
  local changed = {}
  for index, row in ipairs(file.rows) do
    if row.kind ~= "context" then
      for visible_index = math.max(1, index - context_lines), math.min(#file.rows, index + context_lines) do
        changed[visible_index] = true
      end
    end
  end

  if next(changed) == nil then
    return file.rows
  end

  local visible = {}
  local index = 1
  while index <= #file.rows do
    if changed[index] then
      table.insert(visible, file.rows[index])
      index = index + 1
    else
      local first = index
      while index <= #file.rows and not changed[index] do
        index = index + 1
      end
      table.insert(visible, {
        kind = "fold",
        first_row = first,
        last_row = index - 1,
        count = index - first,
      })
    end
  end
  return visible
end

return M

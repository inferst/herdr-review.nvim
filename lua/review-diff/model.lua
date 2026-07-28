local M = {}

---@param old_text string
---@param new_text string
---@return table|nil
function M.inline_ranges(old_text, new_text)
  if old_text == new_text then
    return nil
  end

  local old_length = vim.fn.strchars(old_text)
  local new_length = vim.fn.strchars(new_text)
  local prefix = 0
  while prefix < old_length and prefix < new_length do
    if vim.fn.strcharpart(old_text, prefix, 1) ~= vim.fn.strcharpart(new_text, prefix, 1) then
      break
    end
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < old_length - prefix and suffix < new_length - prefix do
    local old_char = vim.fn.strcharpart(old_text, old_length - suffix - 1, 1)
    local new_char = vim.fn.strcharpart(new_text, new_length - suffix - 1, 1)
    if old_char ~= new_char then
      break
    end
    suffix = suffix + 1
  end

  return {
    old_start = prefix == 0 and 0 or #vim.fn.strcharpart(old_text, 0, prefix),
    old_end = suffix == 0 and #old_text or #vim.fn.strcharpart(old_text, 0, old_length - suffix),
    new_start = prefix == 0 and 0 or #vim.fn.strcharpart(new_text, 0, prefix),
    new_end = suffix == 0 and #new_text or #vim.fn.strcharpart(new_text, 0, new_length - suffix),
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
  return file.new_path or file.old_path or ""
end

local function append_context_rows(rows, old_lines, new_lines, old_start, new_start, old_stop, new_stop)
  while old_start < old_stop and new_start < new_stop do
    table.insert(rows, {
      kind = "context",
      old_line = old_start,
      new_line = new_start,
      old_text = old_lines[old_start],
      new_text = new_lines[new_start],
    })
    old_start = old_start + 1
    new_start = new_start + 1
  end
  return old_start, new_start
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
  local old_count = hunk[2]
  local new_count = hunk[4]
  local old_start_line = hunk_line_start(hunk[1], old_count)
  local new_start_line = hunk_line_start(hunk[3], new_count)
  local old_start, old_end = source_range(old_start_line, old_count)
  local new_start, new_end = source_range(new_start_line, new_count)

  return {
    id = id,
    first_row = first_row,
    last_row = last_row,
    old_start = old_start,
    old_end = old_end,
    new_start = new_start,
    new_end = new_end,
  }
end

local function append_change_rows(rows, old_lines, new_lines, hunk)
  local old_count = hunk[2]
  local new_count = hunk[4]
  local old_start = hunk_line_start(hunk[1], old_count)
  local new_start = hunk_line_start(hunk[3], new_count)
  local count = math.max(old_count, new_count)

  for offset = 0, count - 1 do
    local old_index = offset < old_count and old_start + offset or nil
    local new_index = offset < new_count and new_start + offset or nil
    local old_text = old_index and old_lines[old_index] or nil
    local new_text = new_index and new_lines[new_index] or nil
    local kind = old_index and new_index and (old_text == new_text and "context" or "change")
      or (old_index and "delete" or "add")

    table.insert(rows, {
      kind = kind,
      old_line = old_index,
      new_line = new_index,
      old_text = old_text,
      new_text = new_text,
    })
  end

  return old_start + old_count, new_start + new_count
end

---@param file table
---@param opts table|nil
---@return table
function M.build_file(file, opts)
  opts = opts or {}
  file._visible_rows = nil
  file._visible_context_lines = nil
  local old_lines = split_lines(file.old_text)
  local new_lines = split_lines(file.new_text)
  local result = vim.deepcopy(file)
  result.id = result.id or table.concat({ result.old_path or "", result.new_path or "" }, "\0")
  result.old_lines = old_lines
  result.new_lines = new_lines
  result.rows = {}
  result.hunks = {}

  if result.binary or result.too_large then
    return result
  end

  local total_size = (file.old_text and #file.old_text or 0) + (file.new_text and #file.new_text or 0)
  if total_size > (opts.max_file_size or 1000000) then
    result.too_large = true
    result.rows = {}
    result.hunks = {}
    return result
  end

  local diff_opts = { result_type = "indices", algorithm = opts.algorithm or "histogram" }
  if opts.ignore_whitespace then
    diff_opts.ignore_whitespace = true
  end
  local diff = vim.text and vim.text.diff or vim.diff
  local hunks = diff(table.concat(old_lines, "\n"), table.concat(new_lines, "\n"), diff_opts)
  local old_cursor, new_cursor = 1, 1

  for _, hunk in ipairs(hunks) do
    local old_start = hunk_line_start(hunk[1], hunk[2])
    local new_start = hunk_line_start(hunk[3], hunk[4])
    append_context_rows(result.rows, old_lines, new_lines, old_cursor, new_cursor, old_start, new_start)

    local first_row = #result.rows + 1
    old_cursor, new_cursor = append_change_rows(result.rows, old_lines, new_lines, hunk)
    local last_row = #result.rows

    table.insert(result.hunks, hunk_metadata(#result.hunks + 1, first_row, last_row, hunk))
  end

  append_context_rows(result.rows, old_lines, new_lines, old_cursor, new_cursor, #old_lines + 1, #new_lines + 1)

  for index, source_row in ipairs(result.rows) do
    source_row._source_index = index
  end
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

---@param files table[]
---@param opts table|nil
---@param on_file fun(file: table, index: integer, total: integer)|nil
---@param on_done fun(result: table)|nil
---@param generation_check fun(): boolean|nil
function M.build_async(files, opts, on_file, on_done, generation_check)
  opts = opts or {}
  local result = { files = {} }
  local i = 0
  local batch_size = 3

  local function process_batch()
    if generation_check and not generation_check() then
      return
    end
    local batch_end = math.min(i + batch_size, #files)
    while i < batch_end do
      i = i + 1
      local file = M.build_file(files[i], opts)
      table.insert(result.files, file)
      if on_file then
        on_file(file, i, #files)
      end
    end
    if i < #files then
      vim.schedule(process_batch)
    else
      table.sort(result.files, function(left, right)
        return path_for_sort(left) < path_for_sort(right)
      end)
      if on_done then
        on_done(result)
      end
    end
  end

  vim.schedule(process_batch)
end

---@param file table
---@param context_lines integer
---@return table[]
function M.visible_rows(file, context_lines)
  context_lines = context_lines or 3
  if file._visible_rows and file._visible_context_lines == context_lines then
    return file._visible_rows
  end
  local changed = {}
  for index, row in ipairs(file.rows) do
    if row.kind ~= "context" then
      for visible_index = math.max(1, index - context_lines), math.min(#file.rows, index + context_lines) do
        changed[visible_index] = true
      end
    end
  end

  if next(changed) == nil then
    file._visible_rows = file.rows
    file._visible_context_lines = context_lines
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
  file._visible_rows = visible
  file._visible_context_lines = context_lines
  return visible
end

return M

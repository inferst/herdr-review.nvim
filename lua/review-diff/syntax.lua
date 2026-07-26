local M = {}

local ignored_captures = {
  conceal = true,
  injection = true,
  spell = true,
}

local function source_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true, trimempty = false })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

local function language_for_path(path)
  if not path or not vim.filetype or not vim.filetype.match then
    return nil
  end

  local filetype = vim.filetype.match({ filename = path })
  if not filetype or not vim.treesitter.language.get_lang then
    return nil
  end

  local ok, language = pcall(vim.treesitter.language.get_lang, filetype)
  return ok and language or nil
end

local function add_capture_spans(spans, query, node, bufnr, lines)
  local start_row, start_col, end_row, end_col = node:range()
  if start_row == end_row and start_col >= end_col then
    return
  end

  for row = start_row, math.min(end_row, #lines - 1) do
    local start_column = row == start_row and start_col or 0
    local finish_column = row == end_row and end_col or #lines[row + 1]
    if finish_column > start_column then
      table.insert(spans, {
        line = row + 1,
        start_col = start_column,
        end_col = finish_column,
        hl_group = "@" .. query,
        priority = 100,
      })
    end
  end
end

local function collect_from_buffer(bufnr, language, lines)
  local parser = vim.treesitter.get_parser(bufnr, language)
  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return {}
  end

  local highlight_query = vim.treesitter.query.get(language, "highlights")
  if not highlight_query then
    return {}
  end

  local spans = {}
  for capture_id, node in highlight_query:iter_captures(tree:root(), bufnr, 0, -1) do
    local capture = highlight_query.captures[capture_id]
    local capture_name = capture and capture:match("^([^%.]+)")
    if capture and not ignored_captures[capture_name] then
      add_capture_spans(spans, capture, node, bufnr, lines)
    end
  end
  return spans
end

---@param path string|nil
---@param text string|nil
---@param opts table|nil
---@return table[]
function M.collect(path, text, opts)
  opts = opts or {}
  if opts.enabled == false or opts.engine == "none" or not path or not text or text == "" then
    return {}
  end

  local language = language_for_path(path)
  if not language then
    return {}
  end

  local lines = source_lines(text)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local ok, spans = pcall(function()
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].filetype = vim.filetype.match({ filename = path }) or ""
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return collect_from_buffer(bufnr, language, lines)
  end)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

  if not ok then
    return {}
  end
  return spans
end

return M

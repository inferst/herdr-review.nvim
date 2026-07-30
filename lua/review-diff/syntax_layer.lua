local syntax = require("review-diff.syntax")
local locations = require("review-diff.locations")

local M = {}

local syntax_ns = vim.api.nvim_create_namespace("review-diff-syntax")

---@return integer
function M.namespace()
  return syntax_ns
end

---@param options table
---@return boolean
local function disabled(options)
  local syntax_options = options.syntax
  return syntax_options == false or (type(syntax_options) == "table" and syntax_options.enabled == false)
end

---@param file table
---@param side "old"|"new"
---@return string|nil path, string|nil text
local function syntax_value(file, side)
  local path = locations.path(file, side)
  local text = side == "old" and file.old_text or file.new_text
  return path, text
end

---Sets a single syntax highlight extmark for a span on a 1-based display row.
---@param bufnr integer
---@param row_index integer
---@param span table
local function apply_span(bufnr, row_index, span)
  local start_col = span.start_col
  local end_col = span.end_col
  if end_col > start_col then
    vim.api.nvim_buf_set_extmark(bufnr, syntax_ns, row_index - 1, start_col, {
      end_row = row_index - 1,
      end_col = end_col,
      hl_group = span.hl_group,
      hl_mode = "combine",
      priority = span.priority,
    })
  end
end

---Full re-apply of Tree-sitter syntax across every file and both sides.
---Builds and caches spans on demand and maps them through the view's index.
---@param view table
function M.apply(view)
  for _, side in ipairs({ "old", "new" }) do
    vim.api.nvim_buf_clear_namespace(view[side .. "_buf"], syntax_ns, 0, -1)
  end

  if disabled(view.options) then
    return
  end

  local syntax_options = view.options.syntax
  for _, side in ipairs({ "old", "new" }) do
    local bufnr = view[side .. "_buf"]
    for _, file in ipairs(view.files) do
      local path, text = syntax_value(file, side)
      if path and text and not file.binary and not file.too_large then
        view.syntax_cache[file.id] = view.syntax_cache[file.id] or {}
        local cached = view.syntax_cache[file.id][side]
        if not cached or cached.path ~= path or cached.text ~= text then
          cached = {
            path = path,
            text = text,
            spans = syntax.collect(path, text, syntax_options),
          }
          view.syntax_cache[file.id][side] = cached
        end

        for _, span in ipairs(cached.spans) do
          local row_index = view:location_row({ file = path, side = side, line = span.line })
          if row_index then
            apply_span(bufnr, row_index, span)
          end
        end
      end
    end
  end
end

---Re-applies cached syntax spans for exactly one file within its buffer range,
---leaving every other file's syntax extmarks untouched.
---@param view table
---@param file table
---@param range table {start, count}
function M.apply_for_file(view, file, range)
  vim.api.nvim_buf_clear_namespace(view.old_buf, syntax_ns, range.start - 1, range.start - 1 + range.count)
  vim.api.nvim_buf_clear_namespace(view.new_buf, syntax_ns, range.start - 1, range.start - 1 + range.count)

  if disabled(view.options) or file.binary or file.too_large then
    return
  end

  local cache = view.syntax_cache[file.id]
  local file_index = view.row_index[file.id]
  if not cache or not file_index then
    return
  end

  for _, side in ipairs({ "old", "new" }) do
    local bufnr = view[side .. "_buf"]
    local cached = cache[side]
    local side_index = file_index[side]
    if cached and side_index then
      for _, span in ipairs(cached.spans) do
        local relative = side_index[span.line]
        if relative then
          apply_span(bufnr, range.start + relative - 1, span)
        end
      end
    end
  end
end

return M

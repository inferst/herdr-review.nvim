local model = require("review-diff.model")
local render = require("review-diff.render")
local syntax = require("review-diff.syntax")

local M = {}

local render_ns = vim.api.nvim_create_namespace("review-diff-render")
local annotation_ns = vim.api.nvim_create_namespace("review-diff-annotations")
local syntax_ns = vim.api.nvim_create_namespace("review-diff-syntax")
local cursorline_ns = vim.api.nvim_create_namespace("review-diff-cursorline")
local active_view
local view_counter = 0

local DEFAULT_OPTIONS = {
  context_lines = 3,
  ignore_whitespace = false,
  algorithm = "histogram",
  intra_line = false,
  collapse_on_open = false,
  line_numbers = true,
  highlights = "default",
  max_file_size = 1000000,
  syntax = {
    enabled = true,
    engine = "treesitter",
  },
}

local DEFAULT_KEYMAPS = {
  toggle_file = "<Tab>",
  open_file = "<CR>",
  help = "?",
  close = "q",
  refresh = "R",
  next_file = "]f",
  previous_file = "[f",
  next_hunk = "]c",
  previous_hunk = "[c",
  toggle_fold = "za",
  toggle_all = "zA",
  expand_all = "zR",
  collapse_all = "zM",
}

local function normalize_path(path)
  if not path then
    return nil
  end
  while path:sub(1, 2) == "./" do
    path = path:sub(3)
  end
  return path:gsub("\\", "/")
end

local function same_path(left, right)
  return normalize_path(left) == normalize_path(right)
end

local function valid_tabpage(tabpage)
  return tabpage and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function set_default_highlights(opts)
  if opts.highlights == "default" then
    vim.api.nvim_set_hl(0, "ReviewDiffAdd", { bg = "#2e3a2e", default = true })
    vim.api.nvim_set_hl(0, "ReviewDiffDelete", { bg = "#3a2e2e", default = true })
    vim.api.nvim_set_hl(0, "ReviewDiffChange", { bg = "#2e2e3a", default = true })
    vim.api.nvim_set_hl(0, "ReviewDiffAddIntra", { bg = "#2a6a2a", default = true })
    vim.api.nvim_set_hl(0, "ReviewDiffDeleteIntra", { bg = "#6a2a2a", default = true })
  else
    vim.api.nvim_set_hl(0, "ReviewDiffAdd", { link = "DiffAdd", default = true })
    vim.api.nvim_set_hl(0, "ReviewDiffDelete", { link = "DiffDelete", default = true })
    vim.api.nvim_set_hl(0, "ReviewDiffChange", { link = "DiffChange", default = true })
    vim.api.nvim_set_hl(0, "ReviewDiffAddIntra", { link = "DiffText", default = true })
    vim.api.nvim_set_hl(0, "ReviewDiffDeleteIntra", { link = "DiffText", default = true })
  end
  vim.api.nvim_set_hl(0, "ReviewDiffFileHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "ReviewDiffFold", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ReviewDiffMetadata", { link = "WarningMsg", default = true })
  vim.api.nvim_set_hl(0, "ReviewDiffCommentBorder", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ReviewDiffCommentText", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ReviewDiffCommentTitle", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "ReviewDiffHint", { link = "Comment", default = true })
end

local function create_scratch(name)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  return bufnr
end

local function set_window_options(win)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
  vim.wo[win].scrollbind = true
end

local function file_for_location(files, location)
  if not location or not location.file or not location.side then
    return nil
  end
  for _, file in ipairs(files) do
    local path
    if location.side == "old" then
      path = file.old_path
    else
      path = file.new_path
    end
    if same_path(path, location.file) then
      return file
    end
  end
  return nil
end

local function location_path(file, side)
  if side == "old" then
    return file.old_path
  end
  return file.new_path
end

local function cursor_location_for_window(view, win)
  if not valid_window(win) then
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
  local path = location_path(row.file, side)
  if not line or not path then
    return nil
  end
  return { file = normalize_path(path), side = side, line = line }
end

local function cursor_anchor_for_window(view, win)
  if not valid_window(win) then
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

  local path = location_path(row.file, side)
  if not path then
    return nil
  end
  local location = { file = normalize_path(path), side = side }
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

local function file_metadata(file)
  return {
    id = file.id,
    old_path = file.old_path,
    new_path = file.new_path,
    status = file.status,
    binary = file.binary,
    too_large = file.too_large,
  }
end

local View = {}
View.__index = View

function View:emit(event, ...)
  for _, callback in ipairs(self.listeners[event] or {}) do
    callback(self, ...)
  end
end

---@param event string
---@param callback fun(view: table, ...: any)
---@return fun()
function View:on(event, callback)
  self.listeners[event] = self.listeners[event] or {}
  table.insert(self.listeners[event], callback)
  local active = true
  return function()
    if not active then
      return
    end
    active = false
    for index, candidate in ipairs(self.listeners[event] or {}) do
      if candidate == callback then
        table.remove(self.listeners[event], index)
        break
      end
    end
  end
end

function View:get_spec()
  return vim.deepcopy(self.input.spec)
end

function View:get_review_id()
  return self.input.review_id
end

---@return integer
function View:get_context_radius()
  return self.state.context_lines
end

---@return string|nil
function View:get_repo_root()
  return self.input.repo_root
end

---@param win integer
function View:set_origin(win)
  if not valid_window(win) then
    return
  end
  self.origin = {
    tabpage = vim.api.nvim_get_current_tabpage(),
    win = win,
    bufnr = vim.api.nvim_win_get_buf(win),
  }
end

---@return table|nil
function View:capture_state()
  local review_id = self:get_review_id()
  if not review_id then
    return nil
  end

  local snapshot = {
    review_id = review_id,
    collapsed_files = vim.deepcopy(self.state.collapsed_files),
    expanded_folds = vim.deepcopy(self.state.expanded_folds),
  }

  local current_win = vim.api.nvim_get_current_win()
  local current_side = self.win_sides[current_win]
  local side = current_side or self.last_side
  if current_side then
    self.last_side = current_side
  end
  local win = side and self[side .. "_win"] or nil
  snapshot.cursor = cursor_location_for_window(self, win) or cursor_anchor_for_window(self, win)
  return snapshot
end

---@param snapshot table|nil
function View:restore_state(snapshot)
  if not snapshot or snapshot.review_id ~= self:get_review_id() then
    return
  end

  for id, collapsed in pairs(snapshot.collapsed_files or {}) do
    if self.state.collapsed_files[id] ~= nil then
      self.state.collapsed_files[id] = collapsed
    end
  end
  self.state.expanded_folds = vim.deepcopy(snapshot.expanded_folds or {})

  local cursor = snapshot.cursor
  local cursor_side = cursor and (cursor.side == "old" or cursor.side == "new") and cursor.side or nil
  local cursor_file = cursor_side and file_for_location(self.files, cursor) or nil
  if cursor_file and cursor.line then
    self.state.collapsed_files[cursor_file.id] = false
  end

  self:render()

  if not cursor_file then
    return
  end

  local row_index
  local header_index
  for index, row in ipairs(self.display_rows) do
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
    self.last_side = cursor_side
    self:set_cursor_row(row_index)
    self.last_side = cursor_side
  end
end

function View:get_files()
  local files = {}
  for _, file in ipairs(self.files) do
    table.insert(files, file_metadata(file))
  end
  return files
end

function View:get_display_rows()
  return self.display_rows
end

local function syntax_value(file, side)
  if side == "old" then
    return file.old_path, file.old_text
  end
  return file.new_path, file.new_text
end

function View:apply_syntax(changed_file_ids)
  for _, side in ipairs({ "old", "new" }) do
    if changed_file_ids then
      for file_id, _ in pairs(changed_file_ids) do
        local range = self:_file_row_range(file_id)
        if range then
          vim.api.nvim_buf_clear_namespace(self[side .. "_buf"], syntax_ns, range.first - 1, range.last)
        end
      end
    else
      vim.api.nvim_buf_clear_namespace(self[side .. "_buf"], syntax_ns, 0, -1)
    end
  end

  local syntax_options = self.options.syntax
  if syntax_options == false or (type(syntax_options) == "table" and syntax_options.enabled == false) then
    return
  end

  for _, side in ipairs({ "old", "new" }) do
    local bufnr = self[side .. "_buf"]
    for _, file in ipairs(self.files) do
      if not changed_file_ids or changed_file_ids[file.id] then
        local path, text = syntax_value(file, side)
        if path and text and not file.binary and not file.too_large then
          self.syntax_cache[file.id] = self.syntax_cache[file.id] or {}
          local cached = self.syntax_cache[file.id][side]
          if not cached or cached.path ~= path or cached.text ~= text then
            cached = {
              path = path,
              text = text,
              spans = syntax.collect(path, text, syntax_options),
            }
            self.syntax_cache[file.id][side] = cached
          end

          for _, span in ipairs(cached.spans) do
            local row_index, row = self:location_row({ file = path, side = side, line = span.line })
            if row_index then
              local prefix_width = render.source_prefix_width(row, side, self.options)
              local start_col = prefix_width + span.start_col
              local end_col = prefix_width + span.end_col
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
          end
        end
      end
    end
  end
end

function View:render()
  self.display_rows = render.display_rows(self.files, self.state)
  if self.hint_text then
    local width = vim.api.nvim_win_get_width(self.old_win)
    local hint_lines = render.wrap_hint_text(self.hint_text, width)
    for i = #hint_lines, 1, -1 do
      table.insert(self.display_rows, 1, { display_kind = "hint", hint_text = hint_lines[i] })
    end
    table.insert(self.display_rows, #hint_lines + 1, { display_kind = "hint", hint_text = "" })
  end
  self.rendering = true
  for _, side in ipairs({ "old", "new" }) do
    local bufnr = self[side .. "_buf"]
    local width = vim.api.nvim_win_get_width(self[side .. "_win"])
    local lines = {}
    for _, row in ipairs(self.display_rows) do
      table.insert(lines, render.text(row, side, width, self.options))
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, render_ns, 0, -1)

    for index, row in ipairs(self.display_rows) do
      local line_hl, inline = render.highlight(row, side, self.options)
      if line_hl then
        local col_start = 0
        if row.display_kind == "line" then
          col_start = render.source_prefix_width(row, side, self.options)
        end
        vim.api.nvim_buf_set_extmark(bufnr, render_ns, index - 1, col_start, {
          end_row = index,
          end_col = 0,
          hl_group = line_hl,
          hl_eol = true,
          priority = 50,
        })
      end
      if inline and inline.finish > inline.start then
        vim.api.nvim_buf_set_extmark(bufnr, render_ns, index - 1, inline.start, {
          end_row = index - 1,
          end_col = inline.finish,
          hl_group = inline.hl_group,
          priority = 80,
        })
      end
    end
  end
  self.rendering = false

  self:_rebuild_row_index()

  self:apply_annotations()
  self:update_cursorline()
  self:emit("rendered")
  vim.schedule(function()
    if not self.closed then
      self:apply_syntax()
    end
  end)
end

function View:update_cursorline()
  for _, side in ipairs({ "old", "new" }) do
    local bufnr = self[side .. "_buf"]
    vim.api.nvim_buf_clear_namespace(bufnr, cursorline_ns, 0, -1)

    local win = self[side .. "_win"]
    if valid_window(win) and vim.wo[win].cursorline then
      local row = vim.api.nvim_win_get_cursor(win)[1] - 1
      if row >= 0 and row < vim.api.nvim_buf_line_count(bufnr) then
        vim.api.nvim_buf_set_extmark(bufnr, cursorline_ns, row, 0, {
          line_hl_group = "CursorLine",
          priority = 10000,
        })
      end
    end
  end
end

function View:apply_annotations()
  local result = { applied = {}, stale = {} }
  for _, side in ipairs({ "old", "new" }) do
    vim.api.nvim_buf_clear_namespace(self[side .. "_buf"], annotation_ns, 0, -1)
  end

  for _, id in ipairs(self.annotation_order) do
    local annotation = self.annotations[id]
    if annotation then
      local row_index, row = self:location_row(annotation.location)
      local side = annotation.location and annotation.location.side
      if row_index and side and row.source_row and row.source_row[side .. "_line"] then
        local bufnr = self[side .. "_buf"]
        local win_width = vim.api.nvim_win_get_width(self[side .. "_win"])
        local lines = render.annotation_lines(annotation.text or "", win_width)
        local mark_id = vim.api.nvim_buf_set_extmark(bufnr, annotation_ns, row_index - 1, 0, {
          virt_lines = lines,
          virt_lines_above = false,
        })
        annotation.mark_id = mark_id

        local other_side = side == "old" and "new" or "old"
        local other_bufnr = self[other_side .. "_buf"]
        local empty = {}
        for _ = 1, #lines do
          table.insert(empty, { { "" } })
        end
        vim.api.nvim_buf_set_extmark(other_bufnr, annotation_ns, row_index - 1, 0, {
          virt_lines = empty,
          virt_lines_above = false,
        })

        table.insert(result.applied, id)
      else
        table.insert(result.stale, id)
      end
    end
  end
  self.annotation_result = result
  return result
end

---@param annotations table[]
---@return table
function View:set_annotations(annotations)
  self.annotations = {}
  self.annotation_order = {}
  for _, annotation in ipairs(annotations or {}) do
    if annotation.id then
      local id = tostring(annotation.id)
      self.annotations[id] = vim.deepcopy(annotation)
      table.insert(self.annotation_order, id)
    end
  end
  return self:apply_annotations()
end

---@param annotation table
---@return table
function View:set_annotation(annotation)
  local id = tostring(annotation.id)
  if not self.annotations[id] then
    table.insert(self.annotation_order, id)
  end
  self.annotations[id] = vim.deepcopy(annotation)
  return self:apply_annotations()
end

---@param id string
function View:remove_annotation(id)
  id = tostring(id)
  self.annotations[id] = nil
  for index, candidate in ipairs(self.annotation_order) do
    if candidate == id then
      table.remove(self.annotation_order, index)
      break
    end
  end
  self:apply_annotations()
end

function View:clear_annotations()
  self.annotations = {}
  self.annotation_order = {}
  for _, side in ipairs({ "old", "new" }) do
    vim.api.nvim_buf_clear_namespace(self[side .. "_buf"], annotation_ns, 0, -1)
  end
end

---@param location table
---@return integer|nil, table|nil
function View:location_row(location)
  local file = file_for_location(self.files, location)
  if not file then
    return nil, nil
  end
  local by_file = self._row_index and self._row_index.by_location and self._row_index.by_location[file.id]
  if not by_file then
    return nil, nil
  end
  local key = location.side .. "_" .. location.line
  local index = by_file[key]
  if not index then
    return nil, nil
  end
  return index, self.display_rows[index]
end

---@param file_id string
---@return table|nil
function View:_file_row_range(file_id)
  if self._row_index and self._row_index.by_file_range then
    return self._row_index.by_file_range[file_id]
  end
  return nil
end

function View:_rebuild_row_index()
  self._row_index = { by_location = {}, by_file_header = {}, by_file_range = {} }
  for index, row in ipairs(self.display_rows) do
    if row.display_kind == "line" and row.file_id and row.source_row then
      local by_file = self._row_index.by_location[row.file_id]
      if not by_file then
        by_file = {}
        self._row_index.by_location[row.file_id] = by_file
      end
      for _, side in ipairs({ "old", "new" }) do
        local line = row.source_row[side .. "_line"]
        if line then
          by_file[side .. "_" .. line] = index
        end
      end
    elseif row.display_kind == "file_header" and row.file_id then
      self._row_index.by_file_header[row.file_id] = index
    end
    if row.file_id then
      local range = self._row_index.by_file_range[row.file_id]
      if not range then
        range = { first = index, last = index }
        self._row_index.by_file_range[row.file_id] = range
      else
        range.last = index
      end
    end
  end
end

function View:_build_file_rows(file_id)
  local rows = {}
  for _, file in ipairs(self.files) do
    if file.id == file_id then
      table.insert(rows, {
        display_kind = "file_header",
        file = file,
        file_id = file.id,
        collapsed = self.state.collapsed_files[file.id] == true,
      })
      if not self.state.collapsed_files[file.id] then
        if file.binary or file.too_large then
          table.insert(rows, {
            display_kind = "metadata",
            file = file,
            file_id = file.id,
            text = file.binary and "binary file changed" or "file is too large to diff",
          })
        else
          local visible_rows = model.visible_rows(file, self.state.context_lines)
          for _, row in ipairs(visible_rows) do
            if
              row.kind == "fold"
              and self.state.expanded_folds[string.format("%s:%d:%d", file.id, row.first_row, row.last_row)]
            then
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
      break
    end
  end
  return rows
end

function View:expand_source_row(file, source_index)
  if not file then
    return false
  end
  self.state.collapsed_files[file.id] = false
  if not source_index then
    return true
  end
  for _, row in ipairs(model.visible_rows(file, self.state.context_lines)) do
    if row.kind == "fold" and source_index >= row.first_row and source_index <= row.last_row then
      local key = string.format("%s:%d:%d", file.id, row.first_row, row.last_row)
      self.state.expanded_folds[key] = true
      break
    end
  end
  return true
end

function View:expand_location(location)
  local file = file_for_location(self.files, location)
  if not file then
    return nil
  end
  local side_line = location.side .. "_line"
  local source_index
  for index, row in ipairs(file.rows) do
    if row[side_line] == location.line then
      source_index = index
      break
    end
  end
  self:expand_source_row(file, source_index)
  return file
end

---@param location table
---@return boolean, string|nil
function View:open_location(location)
  if not location or (location.side ~= "old" and location.side ~= "new") then
    return false, "invalid location"
  end
  if not self:expand_location(location) then
    return false, "file not found"
  end
  self:render()
  local row_index = self:location_row(location)
  if not row_index then
    return false, "location is stale"
  end
  local win = self[location.side .. "_win"]
  if not valid_window(win) then
    return false, "review window is closed"
  end
  vim.api.nvim_set_current_tabpage(self.tabpage)
  vim.api.nvim_set_current_win(win)
  self.last_side = location.side
  vim.api.nvim_win_set_cursor(win, { row_index, 0 })
  return true, nil
end

---@return boolean
function View:focus()
  if not valid_tabpage(self.tabpage) then
    return false
  end
  vim.api.nvim_set_current_tabpage(self.tabpage)
  return true
end

function View:get_cursor_location()
  return cursor_location_for_window(self, vim.api.nvim_get_current_win())
end

---@param location table
---@param radius integer|nil
---@return string[]|nil, string|nil
function View:get_context(location, radius)
  local file = file_for_location(self.files, location)
  if not file then
    return nil, "file not found"
  end
  local lines = location.side == "old" and file.old_lines or file.new_lines
  if not location.line or not lines[location.line] then
    return nil, "location is stale"
  end
  radius = radius or self.state.context_lines
  local result = {}
  for index = math.max(1, location.line - radius), math.min(#lines, location.line + radius) do
    table.insert(result, lines[index])
  end
  return result, nil
end

---@param location table
---@param context string|nil
---@param radius integer|nil
---@return table|nil
function View:resolve_location(location, context, radius)
  local file = file_for_location(self.files, location)
  if not file then
    return nil
  end
  local lines = location.side == "old" and file.old_lines or file.new_lines
  if not context or context == "" then
    return lines[location.line] and vim.deepcopy(location) or nil
  end

  radius = radius or self.state.context_lines
  local context_lines = vim.split(context, "\n", { plain = true, trimempty = false })
  local anchor_index = location.line - math.max(1, location.line - radius) + 1
  local best_line
  local best_distance
  for start = 1, #lines - #context_lines + 1 do
    local matches = true
    for offset, expected in ipairs(context_lines) do
      if lines[start + offset - 1] ~= expected then
        matches = false
        break
      end
    end
    if matches then
      local candidate = start + anchor_index - 1
      local distance = math.abs(candidate - location.line)
      if not best_distance or distance < best_distance then
        best_line = candidate
        best_distance = distance
      end
    end
  end
  if not best_line then
    return nil
  end
  local resolved = vim.deepcopy(location)
  resolved.line = best_line
  return resolved
end

function View:set_cursor_row(row_index)
  if #self.display_rows == 0 then
    return
  end
  row_index = math.max(1, math.min(#self.display_rows, row_index))
  local current_win = vim.api.nvim_get_current_win()
  local current_side = self.win_sides[current_win]
  if current_side then
    self.last_side = current_side
  end
  local current_cursor = valid_window(current_win) and vim.api.nvim_win_get_cursor(current_win) or { 1, 0 }
  for _, side in ipairs({ "old", "new" }) do
    local win = self[side .. "_win"]
    if valid_window(win) then
      vim.api.nvim_win_set_cursor(win, { row_index, math.min(current_cursor[2], 0) })
    end
  end
  self:update_cursorline()
end

function View:_replace_file_rows(file_id)
  local file_range = self:_file_row_range(file_id)
  if not file_range then
    return
  end

  local new_rows = self:_build_file_rows(file_id)
  local old_count = file_range.last - file_range.first + 1

  for _ = old_count, 1, -1 do
    table.remove(self.display_rows, file_range.first)
  end
  for i, r in ipairs(new_rows) do
    table.insert(self.display_rows, file_range.first + i - 1, r)
  end

  for _, side in ipairs({ "old", "new" }) do
    local bufnr = self[side .. "_buf"]
    local width = vim.api.nvim_win_get_width(self[side .. "_win"])
    local lines = {}
    for _, r in ipairs(new_rows) do
      table.insert(lines, render.text(r, side, width, self.options))
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, file_range.first - 1, file_range.first - 1 + old_count, false, lines)
    vim.bo[bufnr].modifiable = false

    vim.api.nvim_buf_clear_namespace(bufnr, render_ns, file_range.first - 1, file_range.first - 1 + old_count)

    for local_index, r in ipairs(new_rows) do
      local global_index = file_range.first + local_index - 1
      local line_hl, inline = render.highlight(r, side, self.options)
      if line_hl then
        local col_start = 0
        if r.display_kind == "line" then
          col_start = render.source_prefix_width(r, side, self.options)
        end
        vim.api.nvim_buf_set_extmark(bufnr, render_ns, global_index - 1, col_start, {
          end_row = global_index,
          end_col = 0,
          hl_group = line_hl,
          hl_eol = true,
          priority = 50,
        })
      end
      if inline and inline.finish > inline.start then
        vim.api.nvim_buf_set_extmark(bufnr, render_ns, global_index - 1, inline.start, {
          end_row = global_index - 1,
          end_col = inline.finish,
          hl_group = inline.hl_group,
          priority = 80,
        })
      end
    end
  end

  self:_rebuild_row_index()
  self:apply_annotations()
  self:update_cursorline()
  self:apply_syntax({ [file_id] = true })
  self:emit("rendered")
end

function View:toggle_file_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
  local row = self.display_rows[cursor[1]]
  if not row or not row.file_id then
    return
  end
  local file_id = row.file_id

  self.state.collapsed_files[file_id] = not self.state.collapsed_files[file_id]

  self:_replace_file_rows(file_id)

  if self.state.collapsed_files[file_id] then
    for index, display_row in ipairs(self.display_rows) do
      if display_row.file_id == file_id then
        self:set_cursor_row(index)
        break
      end
    end
  end
end

function View:toggle_fold_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
  local row = self.display_rows[cursor[1]]
  if not row then
    return
  end
  if row.display_kind == "file_header" then
    self:toggle_file_at_cursor()
  elseif row.display_kind == "fold" then
    local file_id = row.file_id
    local target_first = row.fold.first_row
    local target_last = row.fold.last_row
    local key = string.format("%s:%d:%d", file_id, target_first, target_last)
    local was_expanded = self.state.expanded_folds[key]
    self.state.expanded_folds[key] = not was_expanded

    self:_replace_file_rows(file_id)

    if was_expanded then
      for index, display_row in ipairs(self.display_rows) do
        if
          display_row.display_kind == "fold"
          and display_row.file_id == file_id
          and display_row.fold.first_row == target_first
          and display_row.fold.last_row == target_last
        then
          self:set_cursor_row(index)
          break
        end
      end
    end
  end
end

function View:expand_all()
  for _, file in ipairs(self.files) do
    self.state.collapsed_files[file.id] = false
  end
  self.state.expanded_folds = {}
  for _, file in ipairs(self.files) do
    for _, row in ipairs(model.visible_rows(file, self.state.context_lines)) do
      if row.kind == "fold" then
        local key = string.format("%s:%d:%d", file.id, row.first_row, row.last_row)
        self.state.expanded_folds[key] = true
      end
    end
  end
  self:render()
end

function View:collapse_all()
  for _, file in ipairs(self.files) do
    self.state.collapsed_files[file.id] = true
  end
  self.state.expanded_folds = {}
  self:render()
end

function View:toggle_all()
  local all_collapsed = true
  for _, file in ipairs(self.files) do
    if not self.state.collapsed_files[file.id] then
      all_collapsed = false
      break
    end
  end
  for _, file in ipairs(self.files) do
    self.state.collapsed_files[file.id] = not all_collapsed
  end
  self:render()
end

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
  if not row or row.display_kind ~= "line" or not row.source_row then
    return nil
  end
  return row.source_row._source_index
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
  local source_row = file.rows[source_index]
  if not source_row then
    return nil
  end
  local by_file = view._row_index and view._row_index.by_location and view._row_index.by_location[file.id]
  if by_file then
    for _, side in ipairs({ "new", "old" }) do
      local line = source_row[side .. "_line"]
      if line then
        local index = by_file[side .. "_" .. line]
        if index then
          return index
        end
      end
    end
    return nil
  end
  for index, row in ipairs(view.display_rows) do
    if row.display_kind == "line" and row.file == file and row.source_row == source_row then
      return index
    end
  end
  return nil
end

local function file_header_row(view, file)
  if view._row_index and view._row_index.by_file_header then
    return view._row_index.by_file_header[file.id]
  end
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

function View:move_file(direction)
  move_to_rows(self, function(row)
    return row.display_kind == "file_header"
  end, direction)
end

function View:move_hunk(direction)
  local targets = collect_hunk_targets(self)
  if #targets == 0 then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local side = self.win_sides[current_win]
  local target = targets[next_hunk_target_index(self, targets, direction)]
  if not target then
    return
  end

  local row_index = display_row_for_source_index(self, target.file, target.source_index)
  if row_index then
    if side and valid_window(self[side .. "_win"]) then
      vim.api.nvim_set_current_win(self[side .. "_win"])
    end
    self:set_cursor_row(row_index)
    return
  end

  self:expand_source_row(target.file, target.source_index)
  self:render()
  row_index = display_row_for_source_index(self, target.file, target.source_index)
  if row_index then
    if side and valid_window(self[side .. "_win"]) then
      vim.api.nvim_set_current_win(self[side .. "_win"])
    end
    self:set_cursor_row(row_index)
  end
end

function View:sync_cursor()
  if self.syncing then
    return
  end
  local current_win = vim.api.nvim_get_current_win()
  local side = self.win_sides[current_win]
  if not side or not valid_window(current_win) then
    return
  end
  self.syncing = true
  local row = vim.api.nvim_win_get_cursor(current_win)[1]
  for _, other_side in ipairs({ "old", "new" }) do
    local win = self[other_side .. "_win"]
    if valid_window(win) and win ~= current_win then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
    end
  end
  self.syncing = false
end

function View:request_refresh()
  self:emit("refresh_requested")
end

---@param text string
function View:set_status(text)
  self.state.empty_text = text
  self:render()
end

---@param mapping table
function View:map(mapping)
  self.keymaps[mapping.key] = mapping.action or mapping.desc or mapping.key
  for _, side in ipairs({ "old", "new" }) do
    vim.keymap.set("n", mapping.key, mapping.callback, {
      buffer = self[side .. "_buf"],
      desc = mapping.desc or mapping.action,
      silent = true,
    })
  end
end

View.register_keymap = View.map

function View:show_help()
  local lines = { "Review Diff keymaps", "" }
  local keys = {}
  for key, action in pairs(self.keymaps) do
    table.insert(keys, { key = key, action = action })
  end
  table.sort(keys, function(left, right)
    return left.key < right.key
  end)
  for _, item in ipairs(keys) do
    table.insert(lines, string.format("%-12s %s", item.key, item.action))
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = math.min(width + 2, vim.o.columns - 4),
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Review Diff ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  local close = function()
    if valid_window(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "?", close, { buffer = bufnr, silent = true })
end

function View:open_source_at_cursor()
  local location = self:get_cursor_location()
  if not location or location.side ~= "new" then
    return false, "no worktree file at cursor"
  end
  if not self.input.spec or not self.input.spec.new or self.input.spec.new.kind ~= "worktree" then
    return false, "historical files are not opened from review"
  end
  if not valid_tabpage(self.origin.tabpage) or not valid_window(self.origin.win) then
    return false, "origin window is closed"
  end
  local path = vim.fs.joinpath(self.input.repo_root, location.file)
  if not vim.uv.fs_stat(path) then
    return false, "file is not present in the worktree"
  end
  if vim.api.nvim_buf_is_valid(self.origin.bufnr) and vim.bo[self.origin.bufnr].modified then
    return false, "origin buffer has unsaved changes"
  end
  vim.api.nvim_set_current_tabpage(self.origin.tabpage)
  vim.api.nvim_set_current_win(self.origin.win)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(self.origin.win, { location.line, 0 })
  return true, nil
end

function View:replace(input, opts)
  render.clear_text_cache()
  local snapshot = opts and opts.state or self:capture_state()
  local same_review = snapshot and snapshot.review_id == input.review_id
  self.input = vim.deepcopy(input)
  self.files = {}
  self.syntax_cache = {}
  self.state.context_lines = self.options.context_lines
  self.state.empty_text = input.empty_text or "No changes"
  self.state.collapsed_files = same_review and vim.deepcopy(snapshot.collapsed_files or {}) or {}
  self.state.expanded_folds = same_review and vim.deepcopy(snapshot.expanded_folds or {}) or {}

  self._build_generation = (self._build_generation or 0) + 1
  local generation = self._build_generation

  local total = #(input.files or {})
  if total == 0 then
    self:render()
    self:emit("ready")
    self:emit("files_ready")
    return
  end

  self.hint_text = "Resolving diffs…"
  self:render()
  self:emit("ready")

  model.build_async(input.files, self.options, function(file, current, _)
    if self._build_generation ~= generation then
      return
    end
    table.insert(self.files, file)
    if self.state.collapsed_files[file.id] == nil then
      self.state.collapsed_files[file.id] = self.options.collapse_on_open
    end
    self.hint_text = string.format("Processing %d/%d… %s", current, total, file.new_path or file.old_path or "")
    self:render()
  end, function(result)
    if self._build_generation ~= generation then
      return
    end
    self.files = result.files
    for _, file in ipairs(self.files) do
      if self.state.collapsed_files[file.id] == nil then
        self.state.collapsed_files[file.id] = self.options.collapse_on_open
      end
    end
    self.hint_text = nil
    self:render()
    self:place_initial_cursor()
    if same_review then
      self:restore_state(snapshot)
    end
    self:emit("files_ready")
  end, function()
    return self._build_generation == generation
  end)
end

function View:place_initial_cursor()
  local target
  for index, row in ipairs(self.display_rows) do
    if row.display_kind == "line" and row.source_row.kind ~= "context" then
      target = index
      break
    end
  end
  target = target or 1
  self:set_cursor_row(target)
end

function View:dispose()
  if self.closed then
    return
  end
  self.closed = true
  self:emit("closed")
  self.listeners = {}
  if self.autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, self.autocmd_group)
  end
  if active_view == self then
    active_view = nil
  end
end

function View:close()
  if self.closed then
    return
  end
  self:dispose()
  if valid_tabpage(self.tabpage) then
    vim.api.nvim_set_current_tabpage(self.tabpage)
    vim.cmd("tabclose!")
  end
  if valid_tabpage(self.origin.tabpage) then
    vim.api.nvim_set_current_tabpage(self.origin.tabpage)
    if valid_window(self.origin.win) then
      vim.api.nvim_set_current_win(self.origin.win)
    end
  end
end

local function setup_keymaps(view)
  local keymaps = view.options.keymaps or DEFAULT_KEYMAPS
  local function mapping(name, callback, desc)
    local key = keymaps[name]
    if key then
      view:map({ key = key, callback = callback, desc = desc, action = desc })
    end
  end
  mapping("toggle_file", function()
    view:toggle_file_at_cursor()
  end, "Toggle file")
  mapping("open_file", function()
    view:open_source_at_cursor()
  end, "Open worktree file")
  mapping("help", function()
    view:show_help()
  end, "Show keymaps")
  mapping("close", function()
    view:close()
  end, "Close review")
  mapping("refresh", function()
    view:request_refresh()
  end, "Refresh review")
  mapping("next_file", function()
    view:move_file(1)
  end, "Next file")
  mapping("previous_file", function()
    view:move_file(-1)
  end, "Previous file")
  mapping("next_hunk", function()
    view:move_hunk(1)
  end, "Next hunk")
  mapping("previous_hunk", function()
    view:move_hunk(-1)
  end, "Previous hunk")
  mapping("toggle_fold", function()
    view:toggle_fold_at_cursor()
  end, "Toggle context fold")
  mapping("toggle_all", function()
    view:toggle_all()
  end, "Toggle expand/collapse all")
  mapping("expand_all", function()
    view:expand_all()
  end, "Expand all")
  mapping("collapse_all", function()
    view:collapse_all()
  end, "Collapse all")
end

local function setup_autocmds(view)
  local group = vim.api.nvim_create_augroup("ReviewDiff" .. view.id, { clear = true })
  view.autocmd_group = group
  for _, side in ipairs({ "old", "new" }) do
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = group,
      buffer = view[side .. "_buf"],
      callback = function()
        if not view.closed and not view.rendering then
          view.last_side = side
          view:sync_cursor()
          view:update_cursorline()
          view:emit("cursor_moved", view:get_cursor_location())
        end
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = view[side .. "_buf"],
      callback = function()
        if not view.closed then
          view:dispose()
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if not view.closed and not view.rendering and vim.api.nvim_get_current_tabpage() == view.tabpage then
        render.clear_text_cache()
        view:render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not view.closed and not view.rendering and vim.api.nvim_get_current_tabpage() == view.tabpage then
        vim.cmd("wincmd =")
        view:render()
      end
    end,
  })
end

local function open_tab(view)
  vim.cmd("tabnew")
  view.tabpage = vim.api.nvim_get_current_tabpage()
  local placeholder = vim.api.nvim_get_current_buf()
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, view.old_buf)
  vim.cmd("rightbelow vsplit")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, view.new_buf)
  view.old_win = left_win
  view.new_win = right_win
  view.win_sides[left_win] = "old"
  view.win_sides[right_win] = "new"
  set_window_options(left_win)
  set_window_options(right_win)
  if vim.api.nvim_buf_is_valid(placeholder) and placeholder ~= view.old_buf and placeholder ~= view.new_buf then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end
end

---@param input table
---@param opts table|nil
---@return table
function M.open(input, opts)
  opts = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_OPTIONS), M.options or {}, opts or {})
  set_default_highlights(opts)
  view_counter = view_counter + 1

  if active_view and not active_view.closed then
    active_view.options = opts
    active_view:replace(input)
    return active_view
  end

  local current_win = vim.api.nvim_get_current_win()
  local view = setmetatable({
    id = view_counter,
    annotation_ns = annotation_ns,
    input = vim.deepcopy(input),
    options = opts,
    listeners = {},
    annotations = {},
    annotation_order = {},
    syntax_cache = {},
    keymaps = {},
    win_sides = {},
    last_side = "new",
    state = {
      context_lines = opts.context_lines,
      collapsed_files = {},
      expanded_folds = {},
      empty_text = input.empty_text or "No changes",
    },
    origin = {
      tabpage = vim.api.nvim_get_current_tabpage(),
      win = current_win,
      bufnr = vim.api.nvim_win_get_buf(current_win),
    },
  }, View)
  view.old_buf = create_scratch("review-diff://" .. (input.review_id or view.id) .. "/old")
  view.new_buf = create_scratch("review-diff://" .. (input.review_id or view.id) .. "/new")
  view.files = model.build(input.files or {}, opts).files
  for _, file in ipairs(view.files) do
    view.state.collapsed_files[file.id] = opts.collapse_on_open
  end
  active_view = view
  open_tab(view)
  setup_keymaps(view)
  setup_autocmds(view)
  view:render()
  view:place_initial_cursor()
  view:emit("ready")
  view:emit("files_ready")
  return view
end

function M.current()
  return active_view
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_OPTIONS), opts or {})
end

M.View = View

return M

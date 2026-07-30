local model = require("review-diff.model")
local render = require("review-diff.render")
local layout = require("review-diff.layout")
local locations = require("review-diff.locations")
local state_module = require("review-diff.state")
local annotations = require("review-diff.annotations")
local actions = require("review-diff.actions")
local navigation = require("review-diff.navigation")
local incremental = require("review-diff.incremental")
local errors = require("review-diff.errors")
local folds = require("review-diff.folds")
local resolver = require("review-diff.resolver")
local syntax_layer = require("review-diff.syntax_layer")

local cursorline_ns = vim.api.nvim_create_namespace("review-diff-cursorline")

local M = {}

local View = {}
View.__index = View

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

function M.new(fields)
  return setmetatable(fields, View)
end

function View:emit(event, ...)
  for _, callback in ipairs(self.listeners[event] or {}) do
    callback(self, ...)
  end
end

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

function View:get_context_radius()
  return self.state.context_lines
end

function View:get_repo_root()
  return self.input.repo_root
end

function View:metadata()
  return {
    review_id = self:get_review_id(),
    label = self.input.label,
    cwd = self.input.cwd,
    repo_root = self.input.repo_root,
    spec = vim.deepcopy(self.input.spec),
    context_radius = self:get_context_radius(),
    files = self:get_files(),
    actions = vim.deepcopy(self.actions or {}),
  }
end

function View:status()
  if self.closed then
    return "closed"
  end
  if self:get_review_id() == "loading" then
    return "loading"
  end
  local empty_text = self.state and self.state.empty_text or ""
  if type(empty_text) == "string" and empty_text:sub(1, #"Git error:") == "Git error:" then
    return "error"
  end
  return "ready"
end

function View:context(location, opts)
  opts = opts or {}
  local radius = opts.radius or self:get_context_radius()
  return resolver.context(self.files, location, radius)
end

function View:cursor_context(opts)
  opts = opts or {}
  local location = self:get_cursor_location()
  if not location then
    return nil, errors.result("not_on_source_line", "Not on a source line in the review")
  end
  local result = { location = location }
  if opts.include_context then
    local context, err = self:context(location, { radius = opts.radius })
    if not context then
      return nil, err
    end
    result.context = context
  end
  return result, nil
end

function View:buffer_context(bufnr)
  local side
  if bufnr == self.old_buf then
    side = "old"
  elseif bufnr == self.new_buf then
    side = "new"
  end
  if not side then
    return nil, errors.result("not_review_buffer", "Buffer is not part of the review")
  end
  local current = self:get_cursor_location()
  local path = current and current.side == side and current.file or nil
  return { side = side, file = path and { path = path } or nil, path = path }, nil
end

function View:resolve_anchor(anchor, opts)
  opts = opts or {}
  local location = {
    file = anchor and anchor.file,
    side = anchor and anchor.side,
    line = anchor and anchor.line,
  }
  if not location.file or (location.side ~= "old" and location.side ~= "new") or not location.line then
    return nil, errors.result("invalid_location", "Invalid review location")
  end
  local resolved = self:resolve_location(location, anchor.context, opts.radius or self:get_context_radius())
  if not resolved then
    return nil, errors.result("stale_location", "Location is no longer present")
  end
  return resolved, nil
end

function View:set_origin(win)
  if not layout.valid_window(win) then
    return
  end
  self.origin = {
    tabpage = vim.api.nvim_get_current_tabpage(),
    win = win,
    bufnr = vim.api.nvim_win_get_buf(win),
  }
end

function View:capture_state()
  return state_module.capture(self)
end

function View:restore_state(snapshot)
  return state_module.restore(self, snapshot)
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

function View:apply_syntax()
  return syntax_layer.apply(self)
end

---Synchronously drains the async syntax queue, applying all pending
---file highlights. Used in tests and when async = false.
function View:flush_syntax()
  return syntax_layer.flush(self)
end

---Reprioritizes the async syntax queue so visible files are highlighted first.
---Call this on WinScrolled or similar navigation events.
function View:reprioritize_syntax()
  return syntax_layer.reprioritize(self)
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
    incremental.write_rows(self, side, self.display_rows, 0, -1)
  end
  self.rendering = false
  incremental.reindex(self)
  self:apply_syntax()
  self:apply_annotations()
  self:update_cursorline()
  self:emit("rendered")
end

---Re-renders exactly one file in place, leaving every other file's buffer
---lines and extmarks untouched. Falls back to a full render if this file has
---no known position yet (e.g. before the first render).
---@param file table
function View:render_file(file)
  incremental.render_file(self, file)
end

function View:update_cursorline()
  for _, side in ipairs({ "old", "new" }) do
    local bufnr = self[side .. "_buf"]
    vim.api.nvim_buf_clear_namespace(bufnr, cursorline_ns, 0, -1)

    local win = self[side .. "_win"]
    if layout.valid_window(win) and vim.wo[win].cursorline then
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
  return annotations.apply(self)
end

function View:set_annotations(items)
  return annotations.set_all(self, items)
end

function View:sync_annotations(items, opts)
  return annotations.sync(self, items, opts)
end

function View:set_annotation(item)
  return annotations.set_one(self, item)
end

function View:remove_annotation(id)
  return annotations.remove_one(self, id)
end

function View:clear_annotations()
  return annotations.clear(self)
end

function View:location_row(location)
  local file = locations.file_for(self.files, location)
  if not file or not location.line then
    return nil, nil
  end
  local file_index = self.row_index and self.row_index[file.id]
  local side_index = file_index and file_index[location.side]
  local relative = side_index and side_index[location.line]
  if not relative then
    return nil, nil
  end
  local range = self.file_row_ranges and self.file_row_ranges[file.id]
  if not range then
    return nil, nil
  end
  local row_index = range.start + relative - 1
  return row_index, self.display_rows[row_index]
end

function View:expand_source_row(file, source_index)
  return folds.expand_source_row(self, file, source_index)
end

function View:expand_location(location)
  return folds.expand_location(self, location)
end

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
  if not layout.valid_window(win) then
    return false, "review window is closed"
  end
  vim.api.nvim_set_current_tabpage(self.tabpage)
  vim.api.nvim_set_current_win(win)
  self.last_side = location.side
  vim.api.nvim_win_set_cursor(win, { row_index, 0 })
  return true, nil
end

function View:focus()
  if not layout.valid_tabpage(self.tabpage) then
    return false
  end
  vim.api.nvim_set_current_tabpage(self.tabpage)
  return true
end

function View:get_cursor_location()
  return state_module.cursor_location(self, vim.api.nvim_get_current_win())
end

function View:get_context(location, radius)
  return resolver.get_context(self.files, location, radius or self.state.context_lines)
end

function View:resolve_location(location, context, radius)
  return resolver.resolve_location(self.files, location, context, radius or self.state.context_lines)
end

function View:set_cursor_row(row_index)
  navigation.set_cursor_row(self, row_index)
end

function View:toggle_file_at_cursor()
  return folds.toggle_file_at_cursor(self)
end

function View:toggle_fold_at_cursor()
  return folds.toggle_fold_at_cursor(self)
end

function View:expand_all()
  return folds.expand_all(self)
end

function View:collapse_all()
  return folds.collapse_all(self)
end

function View:toggle_all()
  return folds.toggle_all(self)
end

function View:move_file(direction)
  navigation.move_file(self, direction)
end

function View:move_hunk(direction)
  navigation.move_hunk(self, direction)
end

function View:sync_cursor()
  if self.syncing then
    return
  end
  local current_win = vim.api.nvim_get_current_win()
  local side = self.win_sides[current_win]
  if not side or not layout.valid_window(current_win) then
    return
  end
  self.syncing = true
  local row = vim.api.nvim_win_get_cursor(current_win)[1]
  for _, other_side in ipairs({ "old", "new" }) do
    local win = self[other_side .. "_win"]
    if layout.valid_window(win) and win ~= current_win then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
    end
  end
  self.syncing = false
end

function View:request_refresh()
  self:emit("refresh_requested")
end

function View:set_status(text)
  self.state.empty_text = text
  self:render()
end

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

function View:add_action(action)
  return actions.add(self, action)
end

function View:set_actions(items)
  return actions.set_all(self, items)
end

function View:show_help()
  return actions.show_help(self)
end

function View:open_source_at_cursor()
  local location = self:get_cursor_location()
  if not location or location.side ~= "new" then
    return false, "no worktree file at cursor"
  end
  if not self.input.spec or not self.input.spec.new or self.input.spec.new.kind ~= "worktree" then
    return false, "historical files are not opened from review"
  end
  if not layout.valid_tabpage(self.origin.tabpage) or not layout.valid_window(self.origin.win) then
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
  local snapshot = opts and opts.state or self:capture_state()
  local same_review = snapshot and snapshot.review_id == input.review_id
  self.input = vim.deepcopy(input)
  self.files = model.build(input.files or {}, self.options).files
  self.syntax_cache = {}
  self.state.context_lines = self.options.context_lines
  self.state.empty_text = input.empty_text or "No changes"
  self.state.collapsed_files = {}
  for _, file in ipairs(self.files) do
    local saved = same_review and (snapshot.collapsed_files or {})[file.id] or nil
    self.state.collapsed_files[file.id] = saved ~= nil and saved or self.options.collapse_on_open
  end
  self.state.expanded_folds = same_review and vim.deepcopy(snapshot.expanded_folds or {}) or {}
  self:render()
  self:place_initial_cursor()
  self:emit("ready")
  if same_review then
    self:restore_state(snapshot)
  end
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
  if self._on_dispose then
    self._on_dispose(self)
  end
end

function View:close()
  if self.closed then
    return
  end
  self:dispose()
  if layout.valid_tabpage(self.tabpage) then
    vim.api.nvim_set_current_tabpage(self.tabpage)
    vim.cmd("tabclose!")
  end
  if layout.valid_tabpage(self.origin.tabpage) then
    vim.api.nvim_set_current_tabpage(self.origin.tabpage)
    if layout.valid_window(self.origin.win) then
      vim.api.nvim_set_current_win(self.origin.win)
    end
  end
end

M.View = View

return M

local model = require("review-diff.model")
local layout = require("review-diff.layout")
local annotations = require("review-diff.annotations")
local actions = require("review-diff.actions")
local view_module = require("review-diff.view")

local M = {}

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

local function setup_autocmds(view)
  local group = vim.api.nvim_create_augroup("ReviewDiff" .. view.uid, { clear = true })
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

---@param input table
---@param opts table|nil
---@return table
function M.open_resolved(input, opts)
  opts = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_OPTIONS), M.options or {}, opts or {})
  set_default_highlights(opts)
  view_counter = view_counter + 1

  if active_view and not active_view.closed then
    active_view.options = opts
    active_view:replace(input)
    return active_view
  end

  local current_win = vim.api.nvim_get_current_win()
  local view = view_module.new({
    uid = view_counter,
    input = vim.deepcopy(input),
    options = opts,
    listeners = {},
    annotations = {},
    annotation_order = {},
    syntax_cache = {},
    keymaps = {},
    actions = {},
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
  })
  view._on_dispose = function(v)
    if active_view == v then
      active_view = nil
    end
  end
  view.annotation_ns = annotations.get_namespace()
  view.old_buf = layout.create_scratch("review-diff://" .. (input.review_id or view.uid) .. "/old")
  view.new_buf = layout.create_scratch("review-diff://" .. (input.review_id or view.uid) .. "/new")
  view.files = model.build(input.files or {}, opts).files
  for _, file in ipairs(view.files) do
    view.state.collapsed_files[file.id] = opts.collapse_on_open
  end
  active_view = view
  layout.open_tab(view)
  actions.setup_defaults(view, view.options.keymaps or DEFAULT_KEYMAPS)
  setup_autocmds(view)
  view:render()
  view:place_initial_cursor()
  view:emit("ready")
  return view
end

M.open = M.open_resolved

function M.current()
  return active_view
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_OPTIONS), opts or {})
end

M.View = view_module.View

return M

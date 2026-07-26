local config = require("herdr-review.config")
local ui = require("herdr-review.ui")
local session = require("herdr-review.session")
local spec_module = require("review-diff.spec")
local git = require("review-diff.git")
local viewer = require("review-diff")

local M = {}
local setup_options = {}
local active_job
local generation = 0

local function git_completion(arglead)
  local output = vim.fn.systemlist({
    "git",
    "-C",
    vim.fn.getcwd(),
    "for-each-ref",
    "--format=%(refname:short)",
    "refs/heads",
    "refs/remotes",
    "refs/tags",
  })
  local matches = {}
  for _, ref in ipairs(output) do
    if ref:sub(1, #arglead) == arglead then
      table.insert(matches, ref)
    end
  end
  return matches
end

local function attach_view(view)
  if view.herdr_review_attached then
    return
  end
  view.herdr_review_attached = true

  view:on("ready", function(current_view)
    session.on_view_opened(current_view)
  end)
  view:on("closed", function()
    session.on_view_closed()
  end)
  view:on("refresh_requested", function(current_view)
    local current_spec = current_view:get_spec()
    generation = generation + 1
    local refresh_generation = generation
    if active_job then
      active_job:cancel()
    end
    active_job = git.resolve(current_spec, {
      cwd = current_view.input.cwd or vim.fn.getcwd(),
      max_file_bytes = setup_options.max_file_bytes,
      max_file_lines = setup_options.max_file_lines,
    }, {
      on_ready = function(input)
        if refresh_generation == generation and not current_view.closed then
          current_view:replace(input)
        end
      end,
      on_error = function(message)
        if refresh_generation == generation then
          vim.notify(message, vim.log.levels.ERROR)
        end
      end,
    })
  end)

  view:map({
    key = "<leader>" .. config.keymaps.create_comment,
    action = "Add comment",
    desc = "Herdr Review: Add comment",
    callback = ui.create_comment,
  })
  view:map({
    key = "<leader>" .. config.keymaps.open_list,
    action = "Open comment list",
    desc = "Herdr Review: Open comment list",
    callback = ui.open_list,
  })
  view:map({
    key = "<leader>" .. config.keymaps.send_to_agent,
    action = "Send to agent",
    desc = "Herdr Review: Send to agent",
    callback = ui.send_to_agent,
  })
  session.on_view_opened(view)
end

local function start_review(spec)
  generation = generation + 1
  local request_generation = generation
  local cwd = vim.fn.getcwd()
  if active_job then
    active_job:cancel()
    active_job = nil
  end

  local view = viewer.current()
  local created_loading_view = false
  if not view then
    created_loading_view = true
    view = viewer.open({
      cwd = vim.fn.getcwd(),
      repo_root = vim.fn.getcwd(),
      review_id = "loading",
      label = spec_module.label(spec),
      spec = spec,
      files = {},
      empty_text = "Loading Git diff…",
    }, setup_options)
    attach_view(view)
  else
    attach_view(view)
    if vim.api.nvim_get_current_tabpage() ~= view.tabpage then
      view:set_origin(vim.api.nvim_get_current_win())
    end
    view.input.cwd = cwd
    view:focus()
  end

  active_job = git.resolve(spec, {
    cwd = cwd,
    max_file_bytes = setup_options.max_file_bytes,
    max_file_lines = setup_options.max_file_lines,
  }, {
    on_ready = function(input)
      if request_generation ~= generation or view.closed then
        return
      end
      view:replace(input)
      active_job = nil
    end,
    on_error = function(message)
      if request_generation ~= generation then
        return
      end
      if created_loading_view then
        view:set_status("Git error: " .. message)
      end
      vim.notify(message, vim.log.levels.ERROR)
      active_job = nil
    end,
  })
end

function M.setup(opts)
  opts = opts or {}
  setup_options = vim.tbl_deep_extend("force", {
    context_lines = 3,
    ignore_whitespace = false,
    algorithm = "histogram",
    max_file_bytes = 2 * 1024 * 1024,
    max_file_lines = 100000,
  }, opts.diff or {})
  viewer.setup(setup_options)

  if opts.keymaps then
    for key, value in pairs(opts.keymaps) do
      config.keymaps[key] = value
    end
  end

  pcall(vim.api.nvim_del_user_command, "ReviewDiff")
  vim.api.nvim_create_user_command("ReviewDiff", function(command)
    start_review(spec_module.parse(command.fargs))
  end, {
    nargs = "?",
    complete = git_completion,
    desc = "Open a Git review diff",
  })
end

return M

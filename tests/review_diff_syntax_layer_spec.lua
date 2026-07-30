describe("review diff syntax layer async", function()
  local viewer = require("review-diff")
  local view

  after_each(function()
    if view then
      view:close()
      view = nil
    end
  end)

  local function two_file_input(review_id)
    return {
      repo_root = vim.fn.getcwd(),
      review_id = review_id,
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/a.lua",
          old_path = "lua/a.lua",
          new_path = "lua/a.lua",
          old_text = "local a = 1\nlocal b = 2",
          new_text = "local a = 1\nlocal b = 20",
          status = "modified",
        },
        {
          id = "lua/b.lua",
          old_path = "lua/b.lua",
          new_path = "lua/b.lua",
          old_text = "local x = 10\nlocal y = 20",
          new_text = "local x = 10\nlocal y = 200",
          status = "modified",
        },
      },
    }
  end

  it("flush_syntax applies all pending highlights synchronously", function()
    local parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    if not parser_available then
      return
    end

    local syntax_ns = vim.api.nvim_create_namespace("review-diff-syntax")
    view = viewer.open(two_file_input("async-flush"), { context_lines = 1 })

    -- Without flush, extmarks may not be applied yet (async)
    -- After flush, all files must have extmarks
    view:flush_syntax()

    local marks = vim.api.nvim_buf_get_extmarks(view.new_buf, syntax_ns, 0, -1, {})
    assert.is_true(#marks > 0, "expected syntax extmarks after flush_syntax")
  end)

  it("flush_syntax cancels the in-flight async queue", function()
    view = viewer.open(two_file_input("async-cancel"), { context_lines = 1 })

    local gen_before = view._syntax_generation

    -- flush bumps the generation, cancelling any queued ticks
    view:flush_syntax()

    local gen_after = view._syntax_generation
    assert.is_true(gen_after > gen_before, "flush_syntax should bump generation")

    -- After flush, no stale tick should overwrite extmarks:
    -- a new render bumps generation again
    view:render()
    local gen_after_render = view._syntax_generation
    assert.is_true(gen_after_render > gen_after, "render should bump generation again")
  end)

  it("skips syntax for files exceeding max_lines", function()
    local parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    if not parser_available then
      return
    end

    local syntax_ns = vim.api.nvim_create_namespace("review-diff-syntax")
    view = viewer.open(two_file_input("async-maxlines"), {
      context_lines = 1,
      syntax = { enabled = true, engine = "treesitter", async = false, max_lines = 1 },
    })

    -- With max_lines=1, all 2-line files are skipped, so no extmarks
    local marks = vim.api.nvim_buf_get_extmarks(view.new_buf, syntax_ns, 0, -1, {})
    assert.are.equal(0, #marks, "expected no extmarks when all files exceed max_lines")
  end)

  it("async = false applies highlights synchronously without flush", function()
    local parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    if not parser_available then
      return
    end

    local syntax_ns = vim.api.nvim_create_namespace("review-diff-syntax")
    view = viewer.open(two_file_input("async-off"), {
      context_lines = 1,
      syntax = { enabled = true, engine = "treesitter", async = false },
    })

    -- With async=false highlights are applied in render(), no flush needed
    local marks = vim.api.nvim_buf_get_extmarks(view.new_buf, syntax_ns, 0, -1, {})
    assert.is_true(#marks > 0, "expected syntax extmarks when async = false")
  end)
end)

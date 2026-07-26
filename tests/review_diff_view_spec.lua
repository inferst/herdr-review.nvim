describe("review diff view", function()
  local viewer = require("review-diff")
  local view

  after_each(function()
    if view then
      view:close()
      view = nil
    end
  end)

  it("opens aligned unlisted old and new buffers", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-1",
      label = "HEAD..WORKTREE",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\ntwo",
          new_text = "one\nthree",
          status = "modified",
        },
      },
    })

    assert.is_truthy(view)
    assert.is_false(vim.bo[view.old_buf].buflisted)
    assert.is_false(vim.bo[view.new_buf].buflisted)
    assert.are.equal("▼ M lua/example.lua", vim.api.nvim_buf_get_lines(view.old_buf, 0, 1, false)[1])
    assert.are.equal("    2 │ two", vim.api.nvim_buf_get_lines(view.old_buf, 2, 3, false)[1])
    assert.are.equal("    2 │ three", vim.api.nvim_buf_get_lines(view.new_buf, 2, 3, false)[1])
  end)

  it("extends line highlights across the screen line", function()
    local render_ns = vim.api.nvim_create_namespace("review-diff-render")
    local cursorline_ns = vim.api.nvim_create_namespace("review-diff-cursorline")
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-line-highlight",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\ntwo",
          new_text = "one\nthree",
          status = "modified",
        },
      },
    })

    local marks = vim.api.nvim_buf_get_extmarks(view.new_buf, render_ns, 0, -1, { details = true })
    local changed_line_details
    for _, mark in ipairs(marks) do
      if mark[2] == 2 then
        changed_line_details = mark[4]
        break
      end
    end

    assert.are.same("ReviewDiffChange", changed_line_details.line_hl_group)

    local cursorline_marks = vim.api.nvim_buf_get_extmarks(view.new_buf, cursorline_ns, 0, -1, { details = true })
    assert.are.same(1, #cursorline_marks)
    assert.are.same("CursorLine", cursorline_marks[1][4].line_hl_group)
  end)

  it("projects Tree-sitter highlights into the aggregate buffers", function()
    local parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    local syntax_ns = vim.api.nvim_create_namespace("review-diff-syntax")
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-syntax",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "local value = 1",
          new_text = "local value = 2",
          status = "modified",
        },
      },
    })

    local marks = vim.api.nvim_buf_get_extmarks(view.new_buf, syntax_ns, 0, -1, {})
    if parser_available then
      assert.is_true(#marks > 0)
    else
      assert.are.equal(0, #marks)
    end
  end)

  it("keeps the old side empty for an added file", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-added",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          old_path = nil,
          new_path = "lua/added.lua",
          old_text = nil,
          new_text = "one\ntwo",
          status = "added",
        },
      },
    })

    assert.are.equal("▼ A —", vim.api.nvim_buf_get_lines(view.old_buf, 0, 1, false)[1])
    assert.are.equal("▼ A lua/added.lua", vim.api.nvim_buf_get_lines(view.new_buf, 0, 1, false)[1])
    assert.are.equal("      │ ", vim.api.nvim_buf_get_lines(view.old_buf, 1, 2, false)[1])
    assert.are.equal("    1 │ one", vim.api.nvim_buf_get_lines(view.new_buf, 1, 2, false)[1])
    assert.is_nil(view:resolve_location({ file = "lua/added.lua", side = "old", line = 1 }))
  end)

  it("maps the active cursor to a side-specific source location", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-2",
      label = "HEAD..WORKTREE",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\ntwo",
          new_text = "one\nthree",
          status = "modified",
        },
      },
    })

    assert.are.same({ file = "lua/example.lua", side = "new", line = 2 }, view:get_cursor_location())
  end)

  it("places annotations through source locations", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-3",
      label = "HEAD..WORKTREE",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\ntwo",
          new_text = "one\nthree",
          status = "modified",
        },
      },
    })

    local result = view:set_annotations({
      {
        id = "comment-1",
        location = { file = "lua/example.lua", side = "new", line = 2 },
        text = "Review this",
      },
      {
        id = "comment-2",
        location = { file = "lua/example.lua", side = "new", line = 99 },
        text = "Stale",
      },
    })

    assert.are.same({ "comment-1" }, result.applied)
    assert.are.same({ "comment-2" }, result.stale)
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(view.new_buf, view.annotation_ns, 0, -1, {}))
  end)

  it("reanchors a location from its saved context", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-4",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\ntwo\nchanged",
          new_text = "zero\none\ntwo\nchanged",
          status = "modified",
        },
      },
    })

    assert.are.same(
      { file = "lua/example.lua", side = "new", line = 3 },
      view:resolve_location(
        { file = "lua/example.lua", side = "new", line = 2 },
        "one\ntwo\nchanged"
      )
    )
  end)

  it("invalidates itself when the review tab is closed externally", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-external-close",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {},
    })

    vim.api.nvim_set_current_tabpage(view.tabpage)
    vim.cmd("tabclose!")

    assert.is_nil(viewer.current())
  end)
end)

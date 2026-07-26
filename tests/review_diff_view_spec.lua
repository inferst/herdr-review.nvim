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

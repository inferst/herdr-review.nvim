describe("review diff adapter", function()
  local diff = require("herdr-review.diff")
  local viewer = require("review-diff")
  local view

  after_each(function()
    if view then
      view:close()
      view = nil
    end
  end)

  it("returns the side-specific path for the active cursor", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "adapter-1",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/new.lua",
          old_path = "lua/old.lua",
          new_path = "lua/new.lua",
          old_text = "old",
          new_text = "new",
          status = "renamed",
        },
      },
    })

    local file, side, line = diff.get_cursor_context()
    assert.are.equal("lua/new.lua", file)
    assert.are.equal("new", side)
    assert.are.equal(1, line)

    vim.api.nvim_set_current_win(view.old_win)
    file, side, line = diff.get_cursor_context()
    assert.are.equal("lua/old.lua", file)
    assert.are.equal("old", side)
    assert.are.equal(1, line)
  end)

  it("captures viewer buffer context", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "adapter-2",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/init.lua",
          old_path = "lua/init.lua",
          new_path = "lua/init.lua",
          old_text = "old",
          new_text = "new",
          status = "modified",
        },
      },
    })

    local context = diff.capture_buffer_context(view.new_buf)
    assert.are.same({ side = "new", path = "lua/init.lua", file = { path = "lua/init.lua" } }, context)
    assert.are.equal("new", diff.get_buf_side(view.new_buf))
    assert.are.equal("lua/init.lua", diff.get_buf_path(view.new_buf))
  end)
end)

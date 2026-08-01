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
      spec = { base = { kind = "ref", name = "HEAD" }, head = { kind = "worktree" } },
      files = {
        {
          id = "lua/new.lua",
          left_path = "lua/old.lua",
          right_path = "lua/new.lua",
          left_text = "old",
          right_text = "new",
          status = "renamed",
        },
      },
    })

    local file, side, line = diff.get_cursor_context()
    assert.are.equal("lua/new.lua", file)
    assert.are.equal("right", side)
    assert.are.equal(1, line)

    vim.api.nvim_set_current_win(view.left_win)
    file, side, line = diff.get_cursor_context()
    assert.are.equal("lua/old.lua", file)
    assert.are.equal("left", side)
    assert.are.equal(1, line)
  end)
end)

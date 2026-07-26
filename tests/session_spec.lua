describe("review session", function()
  local config = require("herdr-review.config")
  local session = require("herdr-review.session")
  local storage = require("herdr-review.storage")
  local viewer = require("review-diff")
  local data_dir
  local view

  before_each(function()
    data_dir = vim.fn.tempname()
    config.data_dir = data_dir
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "HEAD..WORKTREE",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/init.lua",
          old_path = "lua/init.lua",
          new_path = "lua/init.lua",
          old_text = "one\ntwo\nthree",
          new_text = "one\ntwo\nchanged",
          status = "modified",
        },
      },
    })
  end)

  after_each(function()
    session.reset()
    if view then
      view:close()
      view = nil
    end
    vim.fn.delete(data_dir, "rf")
  end)

  it("loads comments as viewer annotations for the active review", function()
    local _, err = storage.add_comment("HEAD..WORKTREE", {
      id = "comment-1",
      file = "lua/init.lua",
      side = "new",
      line = 3,
      text = "Review this line.",
      created_at = "2026-07-26T00:00:00Z",
    })
    assert.is_nil(err)

    session.on_view_opened(view)

    assert.are.equal("HEAD..WORKTREE", session.get_current_range())
    local marks = vim.api.nvim_buf_get_extmarks(view.new_buf, view.annotation_ns, 0, -1, { details = true })
    assert.are.equal(1, #marks)
    assert.are.same({ { "Review this line.", "Comment" } }, marks[1][4].virt_text)
  end)

  it("does not place direct extmarks outside the buffer", function()
    session.place_extmark(view.new_buf, 100, "Out of range")

    local marks = vim.api.nvim_buf_get_extmarks(view.new_buf, config.ns, 0, -1, {})
    assert.are.equal(0, #marks)
  end)

  it("reanchors comments from their saved context", function()
    local _, err = storage.add_comment("HEAD..WORKTREE", {
      id = "comment-anchor",
      file = "lua/init.lua",
      side = "new",
      line = 2,
      text = "Follow this line.",
      context = "one\ntwo\nchanged",
    })
    assert.is_nil(err)

    view:replace({
      repo_root = vim.fn.getcwd(),
      review_id = "HEAD..WORKTREE",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/init.lua",
          old_path = "lua/init.lua",
          new_path = "lua/init.lua",
          old_text = "one\ntwo\nthree",
          new_text = "zero\none\ntwo\nchanged",
          status = "modified",
        },
      },
    })
    assert.are.same(
      { file = "lua/init.lua", side = "new", line = 3 },
      view:resolve_location({ file = "lua/init.lua", side = "new", line = 2 }, "one\ntwo\nchanged")
    )
    session.on_view_opened(view)

    local stored = storage.get_comments("HEAD..WORKTREE")
    assert.are.equal(3, stored[1].line)
    assert.is_false(session.is_stale("comment-anchor"))
  end)
end)

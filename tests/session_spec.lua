describe("review session", function()
  local config = require("herdr-review.config")
  local diff = require("herdr-review.diff")
  local session = require("herdr-review.session")
  local storage = require("herdr-review.storage")
  local original_get_current_view
  local data_dir
  local bufnr

  before_each(function()
    original_get_current_view = diff.get_current_view
    data_dir = vim.fn.tempname()
    config.data_dir = data_dir
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].swapfile = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three" })
    diff.set_buf_side(bufnr, "new", { path = "lua/init.lua" }, "lua/init.lua")
  end)

  after_each(function()
    session.reset()
    diff.get_current_view = original_get_current_view
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    vim.fn.delete(data_dir, "rf")
  end)

  it("loads comments as extmarks for the active diff range", function()
    local range = "HEAD..WORKDIR"
    local _, err = storage.add_comment(range, {
      id = "comment-1",
      file = "lua/init.lua",
      side = "new",
      line = 2,
      text = "Review this line.",
      created_at = "2026-07-26T00:00:00Z",
    })
    assert.is_nil(err)

    diff.get_current_view = function()
      return { rev_arg = range }
    end

    session.on_view_opened()

    assert.are.equal(range, session.get_current_range())
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns, 0, -1, { details = true })
    assert.are.equal(1, #marks)
    assert.are.same({ { "Review this line.", "Comment" } }, marks[1][4].virt_text)
  end)

  it("does not place comments outside the buffer", function()
    session.place_extmark(bufnr, 10, "Out of range")

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns, 0, -1, {})
    assert.are.equal(0, #marks)
  end)
end)

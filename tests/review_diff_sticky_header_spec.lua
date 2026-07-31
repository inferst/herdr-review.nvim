describe("review diff sticky file header", function()
  local viewer = require("review-diff")
  local view

  after_each(function()
    if view then
      view:close()
      view = nil
    end
  end)

  local function changed_lines(prefix)
    local lines = {}
    for number = 1, 60 do
      table.insert(lines, string.format("%s %d", prefix, number))
    end
    return table.concat(lines, "\n")
  end

  local function input(review_id)
    return {
      repo_root = vim.fn.getcwd(),
      review_id = review_id,
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "old-name.lua\0new-name.lua",
          old_path = "old-name.lua",
          new_path = "new-name.lua",
          old_text = changed_lines("old"),
          new_text = changed_lines("new"),
          status = "renamed",
        },
      },
    }
  end

  local function scroll_past_header(win)
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_cursor(win, { 25, 0 })
      vim.cmd("normal! zt")
    end)
  end

  it("shows the current file header in both diff buffers", function()
    view = viewer.open(input("sticky-header"), { syntax = false })

    scroll_past_header(view.new_win)
    require("review-diff.sticky_header").update(view)

    for _, side in ipairs({ "old", "new" }) do
      local sticky = view.sticky_headers[side]
      assert.is_true(vim.api.nvim_win_is_valid(sticky.win))
      local expected_path = side == "old" and "old-name.lua" or "new-name.lua"
      assert.are.equal("▼ R " .. expected_path .. "  +60 -60", vim.api.nvim_buf_get_lines(sticky.buf, 0, 1, false)[1])
    end

    local namespace = vim.api.nvim_create_namespace("review-diff-sticky-header")
    local marks = vim.api.nvim_buf_get_extmarks(view.new_buf, namespace, 0, -1, { details = true })
    assert.are.same({}, marks)
    marks = vim.api.nvim_buf_get_extmarks(view.sticky_headers.new.buf, namespace, 0, -1, { details = true })
    assert.are.equal("ReviewDiffFileHeader", marks[1][4].hl_group)
    assert.are.equal("ReviewDiffAdd", marks[2][4].hl_group)
    assert.are.equal("ReviewDiffDelete", marks[3][4].hl_group)
  end)

  it("does not create sticky headers when disabled", function()
    view = viewer.open(input("sticky-header-disabled"), { sticky_file_header = false, syntax = false })

    scroll_past_header(view.new_win)
    require("review-diff.sticky_header").update(view)

    assert.is_nil(view.sticky_headers.old.win)
    assert.is_nil(view.sticky_headers.new.win)
  end)
end)

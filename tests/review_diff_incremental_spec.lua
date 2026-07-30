describe("review diff incremental render", function()
  local viewer = require("review-diff")
  local view

  after_each(function()
    if view then
      view:close()
      view = nil
    end
  end)

  local function three_file_input(review_id)
    return {
      repo_root = vim.fn.getcwd(),
      review_id = review_id,
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/a.lua",
          old_path = "lua/a.lua",
          new_path = "lua/a.lua",
          old_text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight",
          new_text = "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight",
          status = "modified",
        },
        {
          id = "lua/b.lua",
          old_path = "lua/b.lua",
          new_path = "lua/b.lua",
          old_text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight",
          new_text = "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight",
          status = "modified",
        },
      },
    }
  end

  local function fold_row_index(current_view, file_id, min_count)
    for index, row in ipairs(current_view.display_rows) do
      if row.display_kind == "fold" and row.file_id == file_id and row.fold.count >= (min_count or 1) then
        return index
      end
    end
    return nil
  end

  local function toggle_fold_in(current_view, file_id, min_count)
    local index = fold_row_index(current_view, file_id, min_count)
    assert.is_truthy(index, "expected a fold row for " .. file_id)
    vim.api.nvim_set_current_tabpage(current_view.tabpage)
    vim.api.nvim_set_current_win(current_view.old_win)
    vim.api.nvim_win_set_cursor(current_view.old_win, { index, 0 })
    current_view:toggle_fold_at_cursor()
  end

  local function buffer_lines(current_view, side, range)
    local bufnr = current_view[side .. "_buf"]
    return vim.api.nvim_buf_get_lines(bufnr, range.start - 1, range.start - 1 + range.count, false)
  end

  it("does not move or change an earlier file when a later file's fold toggles", function()
    view = viewer.open(three_file_input("incremental-earlier-untouched"), { context_lines = 1, syntax = false })

    local range_a_before = vim.deepcopy(view.file_row_ranges["lua/a.lua"])
    local old_lines_before = buffer_lines(view, "old", range_a_before)
    local new_lines_before = buffer_lines(view, "new", range_a_before)

    toggle_fold_in(view, "lua/b.lua")

    local range_a_after = view.file_row_ranges["lua/a.lua"]
    assert.are.same(range_a_before, range_a_after)
    assert.are.same(old_lines_before, buffer_lines(view, "old", range_a_after))
    assert.are.same(new_lines_before, buffer_lines(view, "new", range_a_after))
  end)

  it("shifts a later file's range by the exact row-count delta when an earlier file's fold toggles", function()
    view = viewer.open(three_file_input("incremental-later-shifts"), { context_lines = 1, syntax = false })

    local range_b_before = vim.deepcopy(view.file_row_ranges["lua/b.lua"])
    local old_lines_before = buffer_lines(view, "old", range_b_before)
    local new_lines_before = buffer_lines(view, "new", range_b_before)
    local count_a_before = view.file_row_ranges["lua/a.lua"].count

    toggle_fold_in(view, "lua/a.lua", 2)

    local count_a_after = view.file_row_ranges["lua/a.lua"].count
    local delta = count_a_after - count_a_before
    assert.is_true(delta > 0, "expanding a fold should add rows")

    local range_b_after = view.file_row_ranges["lua/b.lua"]
    assert.are.equal(range_b_before.start + delta, range_b_after.start)
    assert.are.equal(range_b_before.count, range_b_after.count)
    assert.are.same(old_lines_before, buffer_lines(view, "old", range_b_after))
    assert.are.same(new_lines_before, buffer_lines(view, "new", range_b_after))
  end)

  it("keeps location_row resolving correctly for a file after another file's fold toggles", function()
    view = viewer.open(three_file_input("incremental-location-row"), { context_lines = 1, syntax = false })

    toggle_fold_in(view, "lua/a.lua")

    local row_index, row = view:location_row({ file = "lua/b.lua", side = "new", line = 3 })
    assert.is_truthy(row_index)
    assert.are.equal("line", row.display_kind)
    assert.are.equal(3, row.source_row.new_line)
    assert.are.equal("lua/b.lua", row.file_id)
  end)

  it("does not change an earlier collapsed file's header highlight when a later file toggles", function()
    local render_ns = vim.api.nvim_create_namespace("review-diff-render")
    view = viewer.open(three_file_input("incremental-earlier-header-untouched"), { context_lines = 1, syntax = false })

    local function toggle_file(fid)
      local index
      for i, row in ipairs(view.display_rows) do
        if row.display_kind == "file_header" and row.file_id == fid then
          index = i
          break
        end
      end
      assert.is_truthy(index, "expected a file header row for " .. fid)
      vim.api.nvim_set_current_win(view.old_win)
      vim.api.nvim_win_set_cursor(view.old_win, { index, 0 })
      view:toggle_file_at_cursor()
    end

    -- Collapse "lua/a.lua" so it renders as a single header row, directly
    -- adjacent to "lua/b.lua"'s range with no rows in between.
    toggle_file("lua/a.lua")

    local range_a = view.file_row_ranges["lua/a.lua"]
    assert.are.equal(1, range_a.count)
    local function header_mark()
      local marks = vim.api.nvim_buf_get_extmarks(
        view.new_buf,
        render_ns,
        { range_a.start - 1, 0 },
        { range_a.start - 1, -1 },
        { details = true }
      )
      for _, mark in ipairs(marks) do
        if mark[4].hl_group == "ReviewDiffFileHeader" then
          return mark[4]
        end
      end
      return nil
    end

    local header_before = header_mark()
    assert.is_truthy(header_before, "expected a.lua's header to have a render highlight before toggling b.lua")

    toggle_file("lua/b.lua")

    local header_after = header_mark()
    assert.is_truthy(header_after, "a.lua's header highlight must survive toggling the adjacent file below it")
    assert.are.equal(header_before.hl_group, header_after.hl_group)
    assert.are.equal(1, view.file_row_ranges["lua/a.lua"].count)
  end)

  it("does not touch another file's syntax extmarks when a fold toggles", function()
    local parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    if not parser_available then
      return
    end

    local syntax_ns = vim.api.nvim_create_namespace("review-diff-syntax")
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "incremental-syntax-untouched",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/a.lua",
          old_path = "lua/a.lua",
          new_path = "lua/a.lua",
          old_text = "local a = 1\nlocal b = 2\nlocal c = 3",
          new_text = "local a = 1\nlocal b = 20\nlocal c = 3",
          status = "modified",
        },
        {
          id = "lua/b.lua",
          old_path = "lua/b.lua",
          new_path = "lua/b.lua",
          old_text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight",
          new_text = "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight",
          status = "modified",
        },
      },
    }, { context_lines = 1 })

    local range_a = view.file_row_ranges["lua/a.lua"]
    local marks_before =
      vim.api.nvim_buf_get_extmarks(view.new_buf, syntax_ns, range_a.start - 1, range_a.start - 1 + range_a.count - 1, {
        details = true,
      })

    toggle_fold_in(view, "lua/b.lua")

    local marks_after =
      vim.api.nvim_buf_get_extmarks(view.new_buf, syntax_ns, range_a.start - 1, range_a.start - 1 + range_a.count - 1, {
        details = true,
      })

    assert.are.same(marks_before, marks_after)
  end)
end)

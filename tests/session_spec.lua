describe("review session", function()
  local config = require("herdr-review.config")
  local session = require("herdr-review.session")
  local storage = require("herdr-review.storage")
  local viewer = require("review-diff")
  local data_dir
  local view

  local function state_input(review_id)
    return {
      repo_root = vim.fn.getcwd(),
      review_id = review_id,
      spec = { base = { kind = "ref", name = "HEAD" }, head = { kind = "worktree" } },
      files = {
        {
          id = "lua/a.lua",
          left_path = "lua/a.lua",
          right_path = "lua/a.lua",
          left_text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight",
          right_text = "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight",
          status = "modified",
        },
        {
          id = "lua/b.lua",
          left_path = "lua/b.lua",
          right_path = "lua/b.lua",
          left_text = "alpha\nbeta",
          right_text = "alpha\nBETA",
          status = "modified",
        },
      },
    }
  end

  local function set_cursor_at_location(current_view, location)
    local row_index = current_view:location_row(location)
    assert.is_truthy(row_index)
    local win = current_view[location.side .. "_win"]
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row_index, 0 })
  end

  local function first_fold_key(current_view, file_id)
    for _, row in ipairs(current_view.display_rows) do
      if row.file_id == file_id and row.display_kind == "fold" then
        return string.format("%s:%d:%d", file_id, row.fold.first_row, row.fold.last_row)
      end
    end
  end

  before_each(function()
    data_dir = vim.fn.tempname()
    config.data_dir = data_dir
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "HEAD..WORKTREE",
      spec = { base = { kind = "ref", name = "HEAD" }, head = { kind = "worktree" } },
      files = {
        {
          id = "lua/init.lua",
          left_path = "lua/init.lua",
          right_path = "lua/init.lua",
          left_text = "one\ntwo\nthree",
          right_text = "one\ntwo\nchanged",
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
      side = "right",
      line = 3,
      text = "Review this line.",
      created_at = "2026-07-26T00:00:00Z",
    })
    assert.is_nil(err)

    session.on_view_opened(view)

    assert.are.equal("HEAD..WORKTREE", session.get_current_range())
    local marks = vim.api.nvim_buf_get_extmarks(view.right_buf, view.annotation_ns, 0, -1, { details = true })
    assert.are.equal(1, #marks)
    local vl = marks[1][4].virt_lines
    assert.are_not.equal(nil, vl)
    assert.is_true(#vl >= 3)
  end)

  it("keeps comment mutations and annotation refresh behind the session interface", function()
    local comment = {
      id = "comment-session-mutation",
      file = "lua/init.lua",
      side = "right",
      line = 3,
      text = "Review this line.",
      created_at = "2026-07-26T00:00:00Z",
    }

    local added, add_err = session.add_comment("HEAD..WORKTREE", comment)

    assert.is_nil(add_err)
    assert.are.same(comment, added.comments[1])
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(view.right_buf, view.annotation_ns, 0, -1, {}))

    local updated, update_err = session.update_comment("HEAD..WORKTREE", comment.id, { text = "Updated." })

    assert.is_nil(update_err)
    assert.are.equal("Updated.", updated.comments[1].text)

    local deleted, delete_err = session.delete_comment("HEAD..WORKTREE", comment.id)

    assert.is_nil(delete_err)
    assert.are.same({}, deleted.comments)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(view.right_buf, view.annotation_ns, 0, -1, {}))
  end)

  it("reanchors comments from their saved context", function()
    local _, err = storage.add_comment("HEAD..WORKTREE", {
      id = "comment-anchor",
      file = "lua/init.lua",
      side = "right",
      line = 2,
      text = "Follow this line.",
      context = "one\ntwo\nchanged",
    })
    assert.is_nil(err)

    view:replace({
      repo_root = vim.fn.getcwd(),
      review_id = "HEAD..WORKTREE",
      spec = { base = { kind = "ref", name = "HEAD" }, head = { kind = "worktree" } },
      files = {
        {
          id = "lua/init.lua",
          left_path = "lua/init.lua",
          right_path = "lua/init.lua",
          left_text = "one\ntwo\nthree",
          right_text = "zero\none\ntwo\nchanged",
          status = "modified",
        },
      },
    })
    assert.are.same(
      { file = "lua/init.lua", side = "right", line = 3 },
      view:resolve_location({ file = "lua/init.lua", side = "right", line = 2 }, "one\ntwo\nchanged")
    )
    session.on_view_opened(view)

    local stored = storage.get_comments("HEAD..WORKTREE")
    assert.are.equal(3, stored[1].line)
    assert.is_false(session.is_stale("comment-anchor"))
  end)

  it("restores matching view state after closing and reopening a review", function()
    view.options.context_lines = 1
    view.options.collapse_on_open = true
    view.options.syntax = false
    view:replace(state_input("session-state"))
    view.state.collapsed_files["lua/a.lua"] = false
    view.state.collapsed_files["lua/b.lua"] = true
    view:render()
    local fold_key = first_fold_key(view, "lua/a.lua")
    assert.is_truthy(fold_key)
    view.state.expanded_folds[fold_key] = true
    set_cursor_at_location(view, { file = "lua/a.lua", side = "left", line = 3 })
    session.on_view_opened(view)

    session.on_view_closed(view)
    view:close()
    view = viewer.open(state_input("session-state"), { context_lines = 1, collapse_on_open = true, syntax = false })
    session.on_view_opened(view)

    assert.is_false(view.state.collapsed_files["lua/a.lua"])
    assert.is_true(view.state.collapsed_files["lua/b.lua"])
    assert.is_true(view.state.expanded_folds[fold_key])
    vim.api.nvim_set_current_win(view.left_win)
    assert.are.same({ file = "lua/a.lua", side = "left", line = 3, col = 0 }, view:get_cursor_location())
  end)

  it("discards pending state when another review opens first", function()
    view.options.context_lines = 1
    view.options.collapse_on_open = true
    view.options.syntax = false
    view:replace(state_input("session-state-old"))
    view.state.collapsed_files["lua/a.lua"] = false
    view:render()
    set_cursor_at_location(view, { file = "lua/a.lua", side = "right", line = 3 })
    session.on_view_opened(view)

    session.on_view_closed(view)
    view:close()
    view =
      viewer.open(state_input("session-state-other"), { context_lines = 1, collapse_on_open = true, syntax = false })
    session.on_view_opened(view)
    assert.is_true(view.state.collapsed_files["lua/a.lua"])

    view:close()
    view = viewer.open(state_input("session-state-old"), { context_lines = 1, collapse_on_open = true, syntax = false })
    session.on_view_opened(view)
    assert.is_true(view.state.collapsed_files["lua/a.lua"])
  end)

  it("keeps pending state through the loading view", function()
    view.options.context_lines = 1
    view.options.collapse_on_open = true
    view.options.syntax = false
    view:replace(state_input("session-loading"))
    view.state.collapsed_files["lua/a.lua"] = false
    view:render()
    set_cursor_at_location(view, { file = "lua/a.lua", side = "right", line = 3 })
    session.on_view_opened(view)

    session.on_view_closed(view)
    view:close()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "loading",
      spec = { base = { kind = "ref", name = "HEAD" }, head = { kind = "worktree" } },
      files = {},
    }, { context_lines = 1, collapse_on_open = true, syntax = false })
    session.on_view_opened(view)

    local pending = session.get_pending_view_state()
    assert.is_truthy(pending)
    view:replace(state_input("session-loading"), { state = pending })
    session.on_view_opened(view)

    assert.is_false(view.state.collapsed_files["lua/a.lua"])
    vim.api.nvim_set_current_win(view.right_win)
    assert.are.same({ file = "lua/a.lua", side = "right", line = 3, col = 0 }, view:get_cursor_location())
  end)
end)

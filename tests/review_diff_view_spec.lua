describe("review diff view", function()
  local viewer = require("review-diff")
  local view

  after_each(function()
    if view then
      view:close()
      view = nil
    end
  end)

  it("opens resolved input through the named public entrypoint", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-open-resolved",
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
    }, { syntax = false })

    assert.are.equal("review-open-resolved", view:get_review_id())
    assert.are.equal("ready", view:status())
  end)

  describe("review diff rendering internals", function()
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
      assert.are.equal("two", vim.api.nvim_buf_get_lines(view.old_buf, 2, 3, false)[1])
      assert.are.equal("three", vim.api.nvim_buf_get_lines(view.new_buf, 2, 3, false)[1])
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
      }, { intra_line = true, syntax = false })

      local new_marks = vim.api.nvim_buf_get_extmarks(view.new_buf, render_ns, 0, -1, { details = true })
      local new_changed_line_details
      local new_inline_details
      for _, mark in ipairs(new_marks) do
        if mark[2] == 2 and mark[4].hl_group == "ReviewDiffAdd" then
          new_changed_line_details = mark[4]
        elseif mark[2] == 2 and mark[4].hl_group == "ReviewDiffAddIntra" then
          new_inline_details = mark[4]
        end
      end

      assert.is_truthy(new_changed_line_details)
      assert.are.same("ReviewDiffAdd", new_changed_line_details.hl_group)
      assert.is_true(new_changed_line_details.hl_eol)
      assert.is_truthy(new_inline_details)
      assert.is_true(new_changed_line_details.priority < new_inline_details.priority)

      local old_marks = vim.api.nvim_buf_get_extmarks(view.old_buf, render_ns, 0, -1, { details = true })
      local old_changed_line_details
      for _, mark in ipairs(old_marks) do
        if mark[2] == 2 and mark[4].hl_group == "ReviewDiffDelete" then
          old_changed_line_details = mark[4]
          break
        end
      end

      assert.is_truthy(old_changed_line_details)
      assert.are.same("ReviewDiffDelete", old_changed_line_details.hl_group)
      assert.is_true(old_changed_line_details.hl_eol)

      local cursorline_marks = vim.api.nvim_buf_get_extmarks(view.new_buf, cursorline_ns, 0, -1, { details = true })
      assert.are.same(1, #cursorline_marks)
      assert.are.same("CursorLine", cursorline_marks[1][4].line_hl_group)
    end)

    it("keeps intra-line highlights visible over cursorline", function()
      local render_ns = vim.api.nvim_create_namespace("review-diff-render")
      local cursorline_ns = vim.api.nvim_create_namespace("review-diff-cursorline")
      view = viewer.open({
        repo_root = vim.fn.getcwd(),
        review_id = "review-intra-line-highlight",
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
      }, { intra_line = true, syntax = false })

      local marks = vim.api.nvim_buf_get_extmarks(view.new_buf, render_ns, 0, -1, { details = true })
      local inline_details
      for _, mark in ipairs(marks) do
        if mark[2] == 2 and mark[4].hl_group == "ReviewDiffAddIntra" then
          inline_details = mark[4]
          break
        end
      end

      assert.is_truthy(inline_details)
      assert.is_true(inline_details.priority < 10000)

      local cursorline_marks = vim.api.nvim_buf_get_extmarks(view.new_buf, cursorline_ns, 0, -1, { details = true })
      assert.are.same(1, #cursorline_marks)
      assert.are.same("CursorLine", cursorline_marks[1][4].line_hl_group)
      assert.is_true(cursorline_marks[1][4].priority > inline_details.priority)
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
      local render_ns = vim.api.nvim_create_namespace("review-diff-render")
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
      local placeholder = vim.api.nvim_buf_get_lines(view.old_buf, 1, 2, false)[1]
      assert.are.equal("", placeholder)

      local marks = vim.api.nvim_buf_get_extmarks(view.old_buf, render_ns, 0, -1, { details = true })
      local placeholder_details
      for _, mark in ipairs(marks) do
        if mark[2] == 1 then
          placeholder_details = mark[4]
          break
        end
      end
      assert.are.same("ReviewDiffChange", placeholder_details.hl_group)
      assert.is_true(placeholder_details.hl_eol)

      assert.are.equal("one", vim.api.nvim_buf_get_lines(view.new_buf, 1, 2, false)[1])
      assert.is_nil(view:resolve_location({ file = "lua/added.lua", side = "old", line = 1 }))
    end)
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

  it("exposes review metadata without mutable internals", function()
    view = viewer.open({
      cwd = vim.fn.getcwd(),
      repo_root = vim.fn.getcwd(),
      review_id = "review-handle-metadata",
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
    }, { syntax = false })

    local metadata = view:metadata()

    assert.are.equal("review-handle-metadata", view:get_review_id())
    assert.are.equal("review-handle-metadata", metadata.review_id)
    assert.are.equal("HEAD..WORKTREE", metadata.label)
    assert.are.equal(vim.fn.getcwd(), metadata.repo_root)
    assert.are.equal(3, metadata.context_radius)
    assert.are.same({
      {
        id = "lua/example.lua",
        old_path = "lua/example.lua",
        new_path = "lua/example.lua",
        status = "modified",
        binary = nil,
        too_large = nil,
      },
    }, metadata.files)

    metadata.files[1].new_path = "mutated.lua"
    assert.are.equal("lua/example.lua", view:metadata().files[1].new_path)
  end)

  it("returns cursor context with source context", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-handle-cursor",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\ntwo\nthree",
          new_text = "one\nchanged\nthree",
          status = "modified",
        },
      },
    }, { context_lines = 1, syntax = false })

    local cursor, err = view:cursor_context({ include_context = true })

    assert.is_nil(err)
    assert.are.same({ file = "lua/example.lua", side = "new", line = 2 }, cursor.location)
    assert.are.same({ "one", "changed", "three" }, cursor.context.lines)
    assert.are.equal("one\nchanged\nthree", cursor.context.text)
    assert.are.equal(1, cursor.context.start_line)
    assert.are.equal(1, cursor.context.radius)
  end)

  it("returns structured errors when cursor is not on a source line", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-handle-cursor-error",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {},
    }, { syntax = false })

    local cursor, err = view:cursor_context()

    assert.is_nil(cursor)
    assert.are.equal("not_on_source_line", err.code)
  end)

  it("resolves anchors through the public handle", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-handle-anchor",
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
    }, { syntax = false })

    local location = view:resolve_anchor({
      file = "lua/example.lua",
      side = "new",
      line = 2,
      context = "one\ntwo\nchanged",
    })

    assert.are.same({ file = "lua/example.lua", side = "new", line = 3 }, location)
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

    local result = view:sync_annotations({
      {
        id = "comment-1",
        anchor = { file = "lua/example.lua", side = "new", line = 2 },
        text = "Review this",
      },
      {
        id = "comment-2",
        anchor = { file = "lua/example.lua", side = "new", line = 99 },
        text = "Stale",
      },
    })

    assert.are.same({ "comment-1" }, result.applied)
    assert.are.same({ "comment-2" }, result.stale)
    local annotation_ns = require("review-diff.annotations").get_namespace()
    local current_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(current_buf, annotation_ns, 0, -1, {}))
  end)

  it("syncs annotations through anchors and reports moved and stale comments", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-sync-annotations",
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
    }, { context_lines = 1, syntax = false })

    local result = view:sync_annotations({
      {
        id = "comment-1",
        anchor = {
          file = "lua/example.lua",
          side = "new",
          line = 2,
          context = "one\ntwo\nchanged",
        },
        text = "Review this",
      },
      {
        id = "comment-2",
        anchor = {
          file = "lua/example.lua",
          side = "new",
          line = 99,
          context = "missing",
        },
        text = "Stale",
      },
    })

    assert.are.same({ "comment-1" }, result.applied)
    assert.are.same({ "comment-2" }, result.stale)
    assert.are.same({ file = "lua/example.lua", side = "new", line = 3 }, result.resolved["comment-1"])
    assert.are.same({
      location = { file = "lua/example.lua", side = "new", line = 3 },
      context = "one\ntwo\nchanged",
      context_start = 2,
    }, result.moved["comment-1"])
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
      view:resolve_anchor({ file = "lua/example.lua", side = "new", line = 2, context = "one\ntwo\nchanged" })
    )
  end)

  it("moves by hunk instead of changed line", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-hunk-move",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\nold a\nold b\nfour\nfive\nsix",
          new_text = "one\nnew a\nnew b\nfour\nchanged five\nsix",
          status = "modified",
        },
      },
    }, { syntax = false })

    assert.are.same({ file = "lua/example.lua", side = "new", line = 2 }, view:get_cursor_location())

    view:move_hunk(1)

    assert.are.same({ file = "lua/example.lua", side = "new", line = 5 }, view:get_cursor_location())
  end)

  it("wraps hunk navigation at the first and last hunk", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-hunk-wrap",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\nold a\nold b\nfour\nfive\nsix",
          new_text = "one\nnew a\nnew b\nfour\nchanged five\nsix",
          status = "modified",
        },
      },
    }, { syntax = false })

    assert.are.same({ file = "lua/example.lua", side = "new", line = 2 }, view:get_cursor_location())

    view:move_hunk(-1)
    assert.are.same({ file = "lua/example.lua", side = "new", line = 5 }, view:get_cursor_location())

    view:move_hunk(1)
    assert.are.same({ file = "lua/example.lua", side = "new", line = 2 }, view:get_cursor_location())
  end)

  it("opens the target file when hunk navigation lands in a collapsed file", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-hunk-collapsed-file",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/a.lua",
          old_path = "lua/a.lua",
          new_path = "lua/a.lua",
          old_text = "one\ntwo",
          new_text = "one\nchanged two",
          status = "modified",
        },
        {
          id = "lua/b.lua",
          old_path = "lua/b.lua",
          new_path = "lua/b.lua",
          old_text = "alpha\nbeta",
          new_text = "alpha\nchanged beta",
          status = "modified",
        },
      },
    }, { collapse_on_open = true, syntax = false })

    view:move_file(1)

    assert.is_true(view.state.collapsed_files["lua/a.lua"])
    assert.is_true(view.state.collapsed_files["lua/b.lua"])

    view:move_hunk(1)

    assert.is_true(view.state.collapsed_files["lua/a.lua"])
    assert.is_false(view.state.collapsed_files["lua/b.lua"])
    assert.are.same({ file = "lua/b.lua", side = "new", line = 2 }, view:get_cursor_location())
  end)

  it("preserves the active diff side when moving between hunks", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-hunk-side",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "lua/example.lua",
          old_path = "lua/example.lua",
          new_path = "lua/example.lua",
          old_text = "one\nold a\nold b\nfour\nfive\nsix",
          new_text = "one\nnew a\nnew b\nfour\nchanged five\nsix",
          status = "modified",
        },
      },
    }, { syntax = false })

    view:open_location({ file = "lua/example.lua", side = "old", line = 2 })

    view:move_hunk(1)

    assert.are.same({ file = "lua/example.lua", side = "old", line = 5 }, view:get_cursor_location())
  end)

  local function state_input(review_id)
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
          old_text = "alpha\nbeta",
          new_text = "alpha\nBETA",
          status = "modified",
        },
      },
    }
  end

  local function set_cursor_at_location(current_view, location)
    local ok, err = current_view:open_location(location)
    assert.is_true(ok, err and tostring(err) or "open_location failed")
  end

  it("captures layout and side-specific cursor state", function()
    view = viewer.open(state_input("review-state-capture"), { context_lines = 1, syntax = false })
    view.state.collapsed_files["lua/a.lua"] = false
    view.state.collapsed_files["lua/b.lua"] = true
    view:render()

    local fold
    for _, row in ipairs(view.display_rows) do
      if row.file_id == "lua/a.lua" and row.display_kind == "fold" then
        fold = row
        break
      end
    end
    assert.is_truthy(fold)
    local fold_key = string.format("%s:%d:%d", fold.file_id, fold.fold.first_row, fold.fold.last_row)
    view.state.expanded_folds[fold_key] = true

    set_cursor_at_location(view, { file = "lua/a.lua", side = "old", line = 3 })
    local snapshot = view:capture_state()

    assert.are.equal("review-state-capture", snapshot.review_id)
    assert.is_false(snapshot.collapsed_files["lua/a.lua"])
    assert.is_true(snapshot.collapsed_files["lua/b.lua"])
    assert.is_true(snapshot.expanded_folds[fold_key])
    assert.are.same({ file = "lua/a.lua", side = "old", line = 3 }, snapshot.cursor)
  end)

  it("captures the last diff cursor after focus moves to the originating tab", function()
    view = viewer.open(state_input("review-state-focus-away"), { context_lines = 1, syntax = false })
    view.state.collapsed_files["lua/a.lua"] = false
    view:render()
    set_cursor_at_location(view, { file = "lua/a.lua", side = "new", line = 3 })

    vim.api.nvim_set_current_tabpage(view.origin.tabpage)
    vim.api.nvim_set_current_win(view.origin.win)

    local snapshot = view:capture_state()

    assert.are.same({ file = "lua/a.lua", side = "new", line = 3 }, snapshot.cursor)
  end)

  it("captures the path from the active side for renamed files", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-state-rename",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {
        {
          id = "old.lua\0new.lua",
          old_path = "old.lua",
          new_path = "new.lua",
          old_text = "old line",
          new_text = "new line",
          status = "renamed",
        },
      },
    }, { syntax = false })
    set_cursor_at_location(view, { file = "old.lua", side = "old", line = 1 })

    local snapshot = view:capture_state()

    assert.are.same({ file = "old.lua", side = "old", line = 1 }, snapshot.cursor)
  end)

  it("restores state after ready callbacks during same-review replacement", function()
    view =
      viewer.open(state_input("review-state-replace"), { context_lines = 1, collapse_on_open = true, syntax = false })
    view.state.collapsed_files["lua/a.lua"] = false
    view.state.collapsed_files["lua/b.lua"] = true
    view:render()

    local fold
    for _, row in ipairs(view.display_rows) do
      if row.file_id == "lua/a.lua" and row.display_kind == "fold" then
        fold = row
        break
      end
    end
    assert.is_truthy(fold)
    local fold_key = string.format("%s:%d:%d", fold.file_id, fold.fold.first_row, fold.fold.last_row)
    view.state.expanded_folds[fold_key] = true
    set_cursor_at_location(view, { file = "lua/a.lua", side = "new", line = 3 })
    local snapshot = view:capture_state()

    local remove_ready = view:on("ready", function(current_view)
      current_view.state.collapsed_files["lua/a.lua"] = true
      current_view.state.expanded_folds = {}
    end)
    view:replace(state_input("review-state-replace"), { state = snapshot })
    remove_ready()

    assert.is_false(view.state.collapsed_files["lua/a.lua"])
    assert.is_true(view.state.collapsed_files["lua/b.lua"])
    assert.is_true(view.state.expanded_folds[fold_key])
    assert.are.same({ file = "lua/a.lua", side = "new", line = 3 }, view:get_cursor_location())
  end)

  it("resets the layout when replacement changes the review identity", function()
    view = viewer.open(state_input("review-state-old"), { context_lines = 1, collapse_on_open = true, syntax = false })
    view.state.collapsed_files["lua/a.lua"] = false
    view:render()
    set_cursor_at_location(view, { file = "lua/a.lua", side = "new", line = 3 })
    local snapshot = view:capture_state()

    view:replace(state_input("review-state-new"), { state = snapshot })

    assert.is_true(view.state.collapsed_files["lua/a.lua"])
    assert.is_true(view.state.collapsed_files["lua/b.lua"])
    assert.are.equal(1, vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1])
    assert.are.same({}, view.state.expanded_folds)
  end)

  it("registers public actions without exposing keymap internals", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-actions",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {},
    }, { syntax = false })

    local called = false
    local ok, err = view:add_action({
      id = "test.action",
      key = "gx",
      desc = "Test action",
      label = "Run test action",
      callback = function(current_view)
        called = current_view == view
      end,
    })

    assert.is_true(ok)
    assert.is_nil(err)
    vim.cmd("normal gx")

    assert.is_true(called)
    assert.are.equal("Run test action", view:metadata().actions["test.action"])
  end)

  it("invalidates itself when the review tab is closed externally", function()
    view = viewer.open({
      repo_root = vim.fn.getcwd(),
      review_id = "review-external-close",
      spec = { old = { kind = "ref", name = "HEAD" }, new = { kind = "worktree" } },
      files = {},
    })

    view:focus()
    vim.cmd("tabclose!")

    assert.is_nil(viewer.current())
  end)
end)

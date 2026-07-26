describe("Diffview adapter", function()
  local diff = require("herdr-review.diff")
  local original_get_current_win
  local original_get_cursor
  local original_loaded
  local original_preload
  local current_win
  local view

  before_each(function()
    original_get_current_win = vim.api.nvim_get_current_win
    original_get_cursor = vim.api.nvim_win_get_cursor
    original_loaded = package.loaded["diffview.lib"]
    original_preload = package.preload["diffview.lib"]

    current_win = 1
    view = {
      cur_entry = { path = "lua/new.lua", oldpath = "lua/old.lua" },
      cur_layout = {
        a = { id = 1, file = { path = "lua/old.lua" } },
        b = { id = 2, file = { path = "lua/new.lua" } },
      },
    }
    package.loaded["diffview.lib"] = {
      get_current_view = function()
        return view
      end,
    }
    vim.api.nvim_get_current_win = function()
      return current_win
    end
    vim.api.nvim_win_get_cursor = function()
      return { 7, 0 }
    end
  end)

  after_each(function()
    vim.api.nvim_get_current_win = original_get_current_win
    vim.api.nvim_win_get_cursor = original_get_cursor
    package.loaded["diffview.lib"] = original_loaded
    package.preload["diffview.lib"] = original_preload
  end)

  it("returns the side-specific path for the cursor", function()
    local file, side, line = diff.get_cursor_context()

    assert.are.equal("lua/old.lua", file)
    assert.are.equal("old", side)
    assert.are.equal(7, line)

    current_win = 2
    file, side, line = diff.get_cursor_context()

    assert.are.equal("lua/new.lua", file)
    assert.are.equal("new", side)
    assert.are.equal(7, line)
  end)

  it("stores the current buffer context", function()
    local context = diff.capture_buffer_context(42)

    assert.are.same({ side = "old", path = "lua/old.lua", file = view.cur_layout.a.file }, context)
    assert.are.equal("old", diff.get_buf_side(42))
    assert.are.equal("lua/old.lua", diff.get_buf_path(42))
  end)
end)

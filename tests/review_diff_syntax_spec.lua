describe("review diff syntax", function()
  local syntax = require("review-diff.syntax")

  it("does not collect spans when syntax highlighting is disabled", function()
    assert.are.same({}, syntax.collect("example.lua", "local value = 1", { enabled = false }))
    assert.are.same({}, syntax.collect("example.lua", "local value = 1", { engine = "none" }))
  end)

  it("collects Tree-sitter spans when the language parser is available", function()
    local parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    local spans = syntax.collect("example.lua", "local value = 1\nreturn value", { enabled = true })

    if not parser_available then
      assert.are.same({}, spans)
      return
    end

    assert.is_true(#spans > 0)
    assert.is_truthy(spans[1].line)
    assert.is_truthy(spans[1].start_col)
    assert.is_truthy(spans[1].end_col)
    assert.is_truthy(spans[1].hl_group)
  end)

  it("skips collection when text exceeds max_lines", function()
    local text = "local value = 1\nreturn value"
    -- With max_lines=1, a 2-line text should be skipped
    local spans = syntax.collect("example.lua", text, { enabled = true, max_lines = 1 })
    assert.are.same({}, spans)
  end)

  it("collects spans when text is within max_lines", function()
    local parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    local text = "local value = 1"
    -- With max_lines=10, a 1-line text should be processed
    local spans = syntax.collect("example.lua", text, { enabled = true, max_lines = 10 })
    if not parser_available then
      assert.are.same({}, spans)
      return
    end
    assert.is_true(#spans > 0)
  end)
end)

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

  it("collects injection spans for fenced code blocks in markdown", function()
    local lua_parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    local md_parser_available = pcall(vim.treesitter.get_parser, 0, "markdown")

    local text = table.concat({
      "# Heading",
      "",
      "```lua",
      "local x = 1",
      "```",
      "",
    }, "\n")

    local spans = syntax.collect("example.md", text, { enabled = true })

    if not lua_parser_available or not md_parser_available then
      return
    end

    -- There should be spans from both the markdown parser and the injected lua block
    assert.is_true(#spans > 0)

    -- At least one span should be on line 4 (the "local x = 1" line inside the code block)
    local injection_spans = {}
    for _, span in ipairs(spans) do
      if span.line == 4 then
        table.insert(injection_spans, span)
      end
    end
    assert.is_true(#injection_spans > 0, "expected syntax spans inside fenced lua code block")
  end)

  it("does not error when markdown has a fenced block with unknown language", function()
    local text = table.concat({
      "# Heading",
      "",
      "```unknownlang9999",
      "some code here",
      "```",
      "",
    }, "\n")

    -- Should not raise an error; spans from the markdown parser itself are fine
    local ok, result = pcall(syntax.collect, "example.md", text, { enabled = true })
    assert.is_true(ok)
    assert.is_table(result)
  end)
end)

describe("review diff syntax markdown provider", function()
  local markdown = require("review-diff.syntax.markdown")
  local syntax = require("review-diff.syntax")

  it("extracts fenced lua block injection", function()
    local lines = {
      "# Title",
      "",
      "```lua",
      "local x = 1",
      "```",
    }
    local injections = markdown.get_injections(lines, syntax)
    local lua_parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    if not lua_parser_available then
      return
    end
    assert.is_true(#injections == 1)
    assert.are.equal("lua", injections[1].lang)
    assert.are.same({ "local x = 1" }, injections[1].lines)
    assert.are.equal(3, injections[1].line_offset)
  end)

  it("extracts tilde-fenced block injection", function()
    local lines = {
      "~~~lua",
      "return 42",
      "~~~",
    }
    local injections = markdown.get_injections(lines, syntax)
    local lua_parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    if not lua_parser_available then
      return
    end
    assert.is_true(#injections == 1)
    assert.are.equal("lua", injections[1].lang)
    assert.are.same({ "return 42" }, injections[1].lines)
  end)

  it("skips fenced block with no language info", function()
    local lines = {
      "```",
      "some code",
      "```",
    }
    local injections = markdown.get_injections(lines, syntax)
    assert.are.same({}, injections)
  end)

  it("skips fenced block with unknown language", function()
    local lines = {
      "```unknownlang9999",
      "some code",
      "```",
    }
    local injections = markdown.get_injections(lines, syntax)
    assert.are.same({}, injections)
  end)

  it("handles multiple fenced blocks", function()
    local lines = {
      "```lua",
      "local a = 1",
      "```",
      "text",
      "```lua",
      "local b = 2",
      "```",
    }
    local injections = markdown.get_injections(lines, syntax)
    local lua_parser_available = pcall(vim.treesitter.get_parser, 0, "lua")
    if not lua_parser_available then
      return
    end
    assert.are.equal(2, #injections)
    assert.are.same({ "local a = 1" }, injections[1].lines)
    assert.are.same({ "local b = 2" }, injections[2].lines)
  end)
end)

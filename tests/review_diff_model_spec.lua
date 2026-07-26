describe("review diff model", function()
  local model = require("review-diff.model")
  local render = require("review-diff.render")

  it("maps changed source lines to one aligned row", function()
    local file = model.build_file({
      old_path = "lua/example.lua",
      new_path = "lua/example.lua",
      old_text = "one\ntwo",
      new_text = "one\nthree",
      status = "modified",
    })

    assert.are.same({
      {
        kind = "context",
        old_line = 1,
        new_line = 1,
        old_text = "one",
        new_text = "one",
      },
      {
        kind = "change",
        old_line = 2,
        new_line = 2,
        old_text = "two",
        new_text = "three",
      },
    }, file.rows)
  end)

  it("collapses unchanged ranges outside the configured context", function()
    local file = model.build_file({
      old_path = "lua/example.lua",
      new_path = "lua/example.lua",
      old_text = "one\ntwo\nthree\nfour\nfive",
      new_text = "one\ntwo\nchanged\nfour\nfive",
      status = "modified",
    })

    local visible = model.visible_rows(file, 1)

    assert.are.equal("fold", visible[1].kind)
    assert.are.equal(1, visible[1].count)
    assert.are.equal("context", visible[2].kind)
    assert.are.equal("change", visible[3].kind)
    assert.are.equal("context", visible[4].kind)
    assert.are.equal("fold", visible[5].kind)
  end)

  it("keeps additions and deletions aligned with placeholders", function()
    local file = model.build_file({
      old_path = "lua/example.lua",
      new_path = "lua/example.lua",
      old_text = "one",
      new_text = "one\ntwo",
      status = "modified",
    })

    assert.are.same({
      { kind = "context", old_line = 1, new_line = 1, old_text = "one", new_text = "one" },
      { kind = "add", old_line = nil, new_line = 2, old_text = nil, new_text = "two" },
    }, file.rows)
  end)

  it("finds changed ranges inside a replaced line", function()
    assert.are.same({
      old_start = 0,
      old_end = 3,
      new_start = 0,
      new_end = 4,
    }, model.inline_ranges("two", "four"))
  end)

  it("keeps intra-line highlights aligned after six-digit line numbers", function()
    local _, inline = render.highlight({
      display_kind = "line",
      source_row = {
        kind = "change",
        old_line = 100000,
        new_line = 100000,
        old_text = "old",
        new_text = "new",
      },
    }, "new", { intra_line = true })

    assert.are.equal(#string.format("%5d │ ", 100000), inline.start)
  end)

  it("uses line-level highlighting unless intra-line mode is enabled", function()
    local row = {
      display_kind = "line",
      source_row = {
        kind = "change",
        old_line = 1,
        new_line = 1,
        old_text = "old",
        new_text = "new",
      },
    }

    local _, default_inline = render.highlight(row, "new")
    local _, detailed_inline = render.highlight(row, "new", { intra_line = true })

    assert.is_nil(default_inline)
    assert.is_truthy(detailed_inline)
  end)
end)

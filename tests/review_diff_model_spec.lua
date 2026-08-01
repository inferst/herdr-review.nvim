describe("review diff model", function()
  local model = require("review-diff.model")
  local render = require("review-diff.render")

  it("maps changed source lines to one aligned row", function()
    local file = model.build_file({
      left_path = "lua/example.lua",
      right_path = "lua/example.lua",
      left_text = "one\ntwo",
      right_text = "one\nthree",
      status = "modified",
    })

    assert.are.same({
      {
        kind = "context",
        left_line = 1,
        right_line = 1,
        left_text = "one",
        right_text = "one",
      },
      {
        kind = "change",
        left_line = 2,
        right_line = 2,
        left_text = "two",
        right_text = "three",
      },
    }, file.rows)
  end)

  it("records one hunk for a multi-line contiguous change", function()
    local file = model.build_file({
      left_path = "lua/example.lua",
      right_path = "lua/example.lua",
      left_text = "one\nold a\nold b\nfour",
      right_text = "one\nnew a\nnew b\nfour",
      status = "modified",
    })

    assert.are.same({
      {
        id = 1,
        first_row = 2,
        last_row = 3,
        left_start = 2,
        left_end = 3,
        right_start = 2,
        right_end = 3,
      },
    }, file.hunks)
  end)

  it("records separate hunks for separate changed ranges", function()
    local file = model.build_file({
      left_path = "lua/example.lua",
      right_path = "lua/example.lua",
      left_text = "one\ntwo\nthree\nfour",
      right_text = "one\nthree\ninserted\nfour",
      status = "modified",
    })

    assert.are.same({
      {
        id = 1,
        first_row = 2,
        last_row = 2,
        left_start = 2,
        left_end = 2,
        right_start = nil,
        right_end = nil,
      },
      {
        id = 2,
        first_row = 4,
        last_row = 4,
        left_start = nil,
        left_end = nil,
        right_start = 3,
        right_end = 3,
      },
    }, file.hunks)
  end)

  it("keeps binary and too-large files out of hunk navigation", function()
    local binary = model.build_file({
      left_path = "bin/example",
      right_path = "bin/example",
      binary = true,
      status = "binary",
    })
    local too_large = model.build_file({
      left_path = "lua/large.lua",
      right_path = "lua/large.lua",
      too_large = true,
      status = "modified",
    })

    assert.are.same({}, binary.hunks)
    assert.are.same({}, too_large.hunks)
  end)

  it("collapses unchanged ranges outside the configured context", function()
    local file = model.build_file({
      left_path = "lua/example.lua",
      right_path = "lua/example.lua",
      left_text = "one\ntwo\nthree\nfour\nfive",
      right_text = "one\ntwo\nchanged\nfour\nfive",
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
      left_path = "lua/example.lua",
      right_path = "lua/example.lua",
      left_text = "one",
      right_text = "one\ntwo",
      status = "modified",
    })

    assert.are.same({
      { kind = "context", left_line = 1, right_line = 1, left_text = "one", right_text = "one" },
      { kind = "add", left_line = nil, right_line = 2, left_text = nil, right_text = "two" },
    }, file.rows)
  end)

  it("keeps context aligned around middle insertions and deletions", function()
    local inserted = model.build_file({
      left_path = "lua/example.lua",
      right_path = "lua/example.lua",
      left_text = "one\ntwo\nthree",
      right_text = "one\ninserted\ntwo\nthree",
      status = "modified",
    })
    local deleted = model.build_file({
      left_path = "lua/example.lua",
      right_path = "lua/example.lua",
      left_text = "one\ntwo\nthree",
      right_text = "one\nthree",
      status = "modified",
    })

    assert.are.same({
      { kind = "context", left_line = 1, right_line = 1, left_text = "one", right_text = "one" },
      { kind = "add", left_line = nil, right_line = 2, left_text = nil, right_text = "inserted" },
      { kind = "context", left_line = 2, right_line = 3, left_text = "two", right_text = "two" },
      { kind = "context", left_line = 3, right_line = 4, left_text = "three", right_text = "three" },
    }, inserted.rows)
    assert.are.same({
      { kind = "context", left_line = 1, right_line = 1, left_text = "one", right_text = "one" },
      { kind = "delete", left_line = 2, right_line = nil, left_text = "two", right_text = nil },
      { kind = "context", left_line = 3, right_line = 2, left_text = "three", right_text = "three" },
    }, deleted.rows)
  end)

  it("keeps context aligned across separate insertion and deletion hunks", function()
    local file = model.build_file({
      left_path = "lua/example.lua",
      right_path = "lua/example.lua",
      left_text = "one\ntwo\nthree\nfour",
      right_text = "one\nthree\ninserted\nfour",
      status = "modified",
    })

    assert.are.same({
      { kind = "context", left_line = 1, right_line = 1, left_text = "one", right_text = "one" },
      { kind = "delete", left_line = 2, right_line = nil, left_text = "two", right_text = nil },
      { kind = "context", left_line = 3, right_line = 2, left_text = "three", right_text = "three" },
      { kind = "add", left_line = nil, right_line = 3, left_text = nil, right_text = "inserted" },
      { kind = "context", left_line = 4, right_line = 4, left_text = "four", right_text = "four" },
    }, file.rows)
  end)

  it("finds changed ranges inside a replaced line", function()
    assert.are.same({
      left_start = 0,
      left_end = 3,
      right_start = 0,
      right_end = 4,
    }, model.inline_ranges("two", "four"))
  end)

  it("starts intra-line highlights at column 0", function()
    local _, inline = render.highlight({
      display_kind = "line",
      source_row = {
        kind = "change",
        left_line = 100000,
        right_line = 100000,
        left_text = "old",
        right_text = "new",
      },
    }, "right", { intra_line = true })

    assert.are.equal(0, inline.start)
  end)

  it("uses line-level highlighting unless intra-line mode is enabled", function()
    local row = {
      display_kind = "line",
      source_row = {
        kind = "change",
        left_line = 1,
        right_line = 1,
        left_text = "old",
        right_text = "new",
      },
    }

    local default_hl, default_inline = render.highlight(row, "right")
    local _, detailed_inline = render.highlight(row, "right", { intra_line = true })

    assert.are.equal("ReviewDiffAdd", default_hl)
    assert.is_nil(default_inline)
    assert.is_truthy(detailed_inline)

    local left_hl = render.highlight(row, "left")
    assert.are.equal("ReviewDiffDelete", left_hl)
  end)
end)

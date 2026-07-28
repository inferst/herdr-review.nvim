describe("review diff specs", function()
  local spec = require("review-diff.spec")

  it("defaults to HEAD versus the worktree", function()
    assert.are.same({
      operator = "..",
      old = { kind = "ref", name = "HEAD" },
      new = { kind = "worktree" },
    }, spec.parse({}))
  end)

  it("compares a single ref with the worktree", function()
    assert.are.same({
      operator = "..",
      old = { kind = "ref", name = "main" },
      new = { kind = "worktree" },
    }, spec.parse({ "main" }))
  end)

  it("keeps explicit two-ref comparisons intact", function()
    assert.are.same({
      operator = "..",
      old = { kind = "ref", name = "main" },
      new = { kind = "ref", name = "HEAD" },
    }, spec.parse({ "main..HEAD" }))
  end)

  it("supports merge-base comparisons and the worktree pseudo-ref", function()
    assert.are.same({
      operator = "...",
      old = { kind = "ref", name = "main" },
      new = { kind = "worktree" },
    }, spec.parse({ "main...WORKTREE" }))
  end)
end)

describe("wrap_hint_text", function()
  local render = require("review-diff.render")

  it("returns single line when fits width", function()
    local result = render.wrap_hint_text("Hint: ? help | cc comment", 100)
    assert.are.same({ "Hint: ? help | cc comment" }, result)
  end)

  it("wraps into multiple lines when exceeds width", function()
    local result = render.wrap_hint_text("Hint: ? help | cc comment | cd delete", 35)
    assert.are.same({ "Hint: ? help | cc comment", "  cd delete" }, result)
  end)

  it("wraps each segment individually when very narrow", function()
    local result = render.wrap_hint_text("Hint: ? help | cc comment | cd delete", 10)
    assert.are.same({ "Hint: ? help", "  cc comment", "  cd delete" }, result)
  end)

  it("handles empty hint", function()
    local result = render.wrap_hint_text("", 80)
    assert.are.same({}, result)
  end)

  it("handles nil hint", function()
    local result = render.wrap_hint_text(nil, 80)
    assert.are.same({}, result)
  end)
end)

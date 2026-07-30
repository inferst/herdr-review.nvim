describe("review spec parser", function()
  local spec = require("herdr-review.spec")

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

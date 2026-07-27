describe("review paths", function()
  local paths = require("herdr-review.paths")

  it("normalizes relative path prefixes", function()
    assert.are.equal("lua/init.lua", paths.normalize("./lua/init.lua"))
    assert.are.equal("lua/init.lua", paths.normalize("lua/init.lua"))
  end)

  it("compares paths after normalization", function()
    assert.is_true(paths.equal("./lua/init.lua", "lua/init.lua"))
    assert.is_false(paths.equal("lua/init.lua", "lua/main.lua"))
  end)
end)

describe("review diff locations", function()
  local locations = require("review-diff.locations")

  it("normalizes relative and platform-specific paths", function()
    assert.are.equal("lua/init.lua", locations.normalize("./lua\\init.lua"))
  end)

  it("resolves a file using the path for the requested side", function()
    local file = {
      old_path = "old.lua",
      new_path = "new.lua",
    }

    assert.are.equal("old.lua", locations.path(file, "old"))
    assert.are.equal("new.lua", locations.path(file, "new"))
    assert.is_nil(locations.path({ new_path = "new.lua" }, "old"))
    assert.are.equal(file, locations.file_for({ file }, { file = "./new.lua", side = "new" }))
    assert.is_nil(locations.file_for({ file }, { file = "missing.lua", side = "new" }))
  end)
end)

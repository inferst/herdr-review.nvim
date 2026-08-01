describe("review diff locations", function()
  local locations = require("review-diff.locations")

  it("normalizes relative and platform-specific paths", function()
    assert.are.equal("lua/init.lua", locations.normalize("./lua\\init.lua"))
  end)

  it("resolves a file using the path for the requested side", function()
    local file = {
      left_path = "old.lua",
      right_path = "new.lua",
    }

    assert.are.equal("old.lua", locations.path(file, "left"))
    assert.are.equal("new.lua", locations.path(file, "right"))
    assert.is_nil(locations.path({ right_path = "new.lua" }, "left"))
    assert.are.equal(file, locations.file_for({ file }, { file = "./new.lua", side = "right" }))
    assert.is_nil(locations.file_for({ file }, { file = "missing.lua", side = "right" }))
  end)
end)

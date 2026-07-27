describe("review comments", function()
  local comments = require("herdr-review.comments")

  it("sorts comments by file, side, line, and id", function()
    local input = {
      { id = "new-late", file = "b.lua", side = "new", line = 8 },
      { id = "old", file = "a.lua", side = "old", line = 3 },
      { id = "new", file = "a.lua", side = "new", line = 2 },
      { id = "new-early", file = "b.lua", side = "new", line = 2 },
    }

    local sorted = comments.sort(input)

    assert.are.same({ "old", "new", "new-early", "new-late" }, {
      sorted[1].id,
      sorted[2].id,
      sorted[3].id,
      sorted[4].id,
    })
    assert.are.equal("new-late", input[1].id)
  end)

  it("finds the comment occupying a diff position", function()
    local comment = { id = "comment-1", file = "lua/init.lua", side = "new", line = 17 }

    assert.are.equal(comment, comments.find_at({ comment }, "lua/init.lua", "new", 17))
    assert.is_nil(comments.find_at({ comment }, "lua/init.lua", "old", 17))
    assert.is_nil(comments.find_at({ comment }, "lua/init.lua", "new", 18))
  end)
end)

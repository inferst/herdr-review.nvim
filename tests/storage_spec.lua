describe("review storage", function()
  local config = require("herdr-review.config")
  local storage = require("herdr-review.storage")
  local data_dir

  before_each(function()
    data_dir = vim.fn.tempname()
    config.data_dir = data_dir
  end)

  after_each(function()
    vim.fn.delete(data_dir, "rf")
  end)

  it("starts a new v4 session when no file exists", function()
    local data, err = storage.load("HEAD..WORKDIR")

    assert.is_nil(err)
    assert.are.same({ version = 4, review_id = "HEAD..WORKDIR", comments = {} }, data)
  end)

  it("supports comment CRUD", function()
    local comment = {
      id = "comment-1",
      file = "lua/init.lua",
      side = "right",
      line = 10,
      text = "Extract this block.",
      context = "local value = true",
      created_at = "2026-07-26T00:00:00Z",
    }

    local added, add_err = storage.add_comment("HEAD..WORKDIR", comment)
    assert.is_nil(add_err)
    assert.are.same(comment, added.comments[1])

    local updated, update_err = storage.update_comment("HEAD..WORKDIR", "comment-1", {
      text = "Extract this branch.",
    })
    assert.is_nil(update_err)
    assert.are.equal("Extract this branch.", updated.comments[1].text)

    local deleted, delete_err = storage.delete_comment("HEAD..WORKDIR", "comment-1")
    assert.is_nil(delete_err)
    assert.are.same({}, deleted.comments)
  end)

  it("reports malformed session data without replacing it", function()
    local range = "HEAD..WORKDIR"
    local _, save_err = storage.save(range, { version = 4, review_id = range, comments = {} })
    assert.is_nil(save_err)

    local session_file = vim.fn.glob(data_dir .. "/sessions/*.json")
    assert.are.equal(data_dir .. "/sessions/" .. vim.fn.sha256(range) .. ".json", session_file)
    vim.fn.writefile({ "not json" }, session_file)

    local data, err = storage.load(range)

    assert.is_nil(data)
    assert.is_truthy(err)
    assert.are.same({ "not json" }, vim.fn.readfile(session_file))
  end)

  it("generates IDs without an external command", function()
    local first = storage.generate_id()
    local second = storage.generate_id()

    assert.is_true(first ~= "")
    assert.is_true(second ~= "")
    assert.is_not.equal(first, second)
  end)
end)

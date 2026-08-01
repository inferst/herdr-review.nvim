describe("herdr review git adapter", function()
  local git = require("herdr-review.git")

  it("parses modified, added, deleted, and renamed paths", function()
    local files = git.parse_name_status(table.concat({
      "M",
      "lua/changed.lua",
      "A",
      "lua/added.lua",
      "D",
      "lua/deleted.lua",
      "R100",
      "lua/old.lua",
      "lua/new.lua",
      "",
    }, "\0"))

    assert.are.same({
      { status = "modified", left_path = "lua/changed.lua", right_path = "lua/changed.lua" },
      { status = "added", left_path = nil, right_path = "lua/added.lua" },
      { status = "deleted", left_path = "lua/deleted.lua", right_path = nil },
      { status = "renamed", left_path = "lua/old.lua", right_path = "lua/new.lua" },
    }, files)
  end)

  it("resolves a worktree diff without changing the repository", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.system({ "git", "-C", root, "init", "-q" })
    vim.fn.writefile({ "one" }, root .. "/example.txt")
    vim.fn.system({ "git", "-C", root, "add", "example.txt" })
    vim.fn.system({
      "git",
      "-C",
      root,
      "-c",
      "user.name=Review Test",
      "-c",
      "user.email=review@example.com",
      "commit",
      "-qm",
      "initial",
    })
    vim.fn.writefile({ "two" }, root .. "/example.txt")

    local resolved
    local failure
    git.resolve(require("herdr-review.spec").parse({}), { cwd = root }, {
      on_ready = function(model)
        resolved = model
      end,
      on_error = function(message)
        failure = message
      end,
    })
    vim.wait(5000, function()
      return resolved ~= nil or failure ~= nil
    end, 20)

    assert.is_nil(failure)
    assert.is_truthy(resolved)
    assert.are.equal(vim.uv.fs_realpath(root), resolved.repo_root)
    assert.are.equal(1, #resolved.files)
    assert.are.equal("example.txt", resolved.files[1].right_path)
    assert.are.equal("one\n", resolved.files[1].left_text)
    assert.are.equal("two\n", resolved.files[1].right_text)
    assert.are.same({ "two" }, vim.fn.readfile(root .. "/example.txt"))

    vim.fn.delete(root, "rf")
  end)
end)

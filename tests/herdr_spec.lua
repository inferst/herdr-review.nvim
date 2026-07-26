describe("herdr prompt", function()
  local herdr = require("herdr-review.herdr")

  it("includes the review range and each comment", function()
    local prompt = herdr.build_prompt("HEAD..WORKDIR", {
      {
        file = "lua/example.lua",
        side = "new",
        line = 12,
        text = "Use a named helper here.",
      },
      {
        file = "lua/old.lua",
        side = "old",
        line = 4,
        text = "Remove this branch.",
      },
    })

    assert.is_true(prompt:find("Diff range: HEAD..WORKDIR", 1, true) ~= nil)
    assert.is_true(prompt:find("File: lua/example.lua (new, line 12)", 1, true) ~= nil)
    assert.is_true(prompt:find("Comment: Use a named helper here.", 1, true) ~= nil)
    assert.is_true(prompt:find("File: lua/old.lua (old, line 4)", 1, true) ~= nil)
    assert.is_true(prompt:find("Comment: Remove this branch.", 1, true) ~= nil)
  end)
end)

describe("herdr CLI adapter", function()
  local herdr = require("herdr-review.herdr")
  local original_run
  local original_is_installed

  before_each(function()
    original_run = herdr.run
    original_is_installed = herdr.is_installed
    herdr.is_installed = function()
      return true
    end
  end)

  after_each(function()
    herdr.run = original_run
    herdr.is_installed = original_is_installed
  end)

  it("decodes agents from the CLI response", function()
    herdr.run = function(args)
      if args[2] == "status" then
        return 0, "", ""
      end
      return 0,
        vim.json.encode({
          result = {
            agents = {
              {
                agent = "reviewer",
                agent_status = "idle",
                pane_id = "pane-1",
                cwd = "/project",
              },
            },
          },
        }),
        ""
    end

    local agents, err = herdr.list_agents()

    assert.are.equal("", err)
    assert.are.same({
      { name = "reviewer", status = "idle", pane_id = "pane-1", cwd = "/project" },
    }, agents)
  end)

  it("passes CLI arguments without shell interpolation", function()
    local actual_args
    herdr.run = function(args)
      actual_args = args
      return 0, "", ""
    end

    local ok, err = herdr.send_text("pane-1", "text with spaces; and symbols")

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.same({ "herdr", "pane", "send-text", "pane-1", "text with spaces; and symbols" }, actual_args)
  end)
end)

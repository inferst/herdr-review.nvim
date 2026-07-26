describe("herdr prompt", function()
  local herdr = require("herdr-review.herdr")

  it("formats comments with their diff side and context", function()
    local prompt = herdr.build_prompt("HEAD..WORKDIR", {
      {
        file = "crates/plugin/src/runtime.rs",
        side = "old",
        line = 109,
        text = "Test comment 1",
        context = "        // A broken Plugin is isolated to its own status. Startup must still",
      },
      {
        file = "crates/plugin/src/runtime.rs",
        side = "new",
        line = 118,
        text = "Test comment 2",
        context = "    // Test changes in file",
      },
    })

    assert.are.equal(
      table.concat({
        "You are reviewing code. Here are the review comments for this diff.",
        "",
        "Diff range: HEAD..WORKDIR",
        "",
        "crates/plugin/src/runtime.rs:109 (removed)",
        "-        // A broken Plugin is isolated to its own status. Startup must still",
        "Test comment 1",
        "",
        "crates/plugin/src/runtime.rs:118",
        "+    // Test changes in file",
        "Test comment 2",
        "",
        "Please fix all issues mentioned above.",
      }, "\n"),
      prompt
    )
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

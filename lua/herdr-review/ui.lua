local comments = require("herdr-review.ui.comments")
local agent = require("herdr-review.ui.agent")
local list = require("herdr-review.ui.list")

local M = {}

M.create_comment = comments.create_comment
M.delete_comment_at_cursor = comments.delete_comment_at_cursor
M.edit_comment = comments.edit_comment
M.open_list = list.open_list
M.jump_to_comment = list.jump_to_comment
M.send_to_agent = agent.send_to_agent

return M

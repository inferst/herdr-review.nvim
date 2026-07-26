local comments = require("herdr-review.comments")
local diff = require("herdr-review.diff")
local paths = require("herdr-review.paths")
local session = require("herdr-review.session")
local storage = require("herdr-review.storage")

local M = {}

local function notify_storage_error(err)
  vim.notify(err or "Could not access review session", vim.log.levels.ERROR)
end

---@param range string
---@return ReviewComment[]|nil
local function load_comments(range)
  local stored, err = storage.get_comments(range)
  if not stored then
    notify_storage_error(err)
    return nil
  end
  return stored
end

function M.create_comment()
  local file, side, line = diff.get_cursor_context()
  if not file or not side or not line then
    vim.notify("Not in a diff view", vim.log.levels.WARN)
    return
  end

  local range = session.get_current_range()
  if not range then
    vim.notify("No active review session", vim.log.levels.WARN)
    return
  end

  file = paths.normalize(file)
  local stored = load_comments(range)
  if not stored then
    return
  end
  local existing_comment = comments.find_at(stored, file, side, line)

  vim.ui.input({
    prompt = existing_comment and "Edit comment: " or "Comment: ",
    default = existing_comment and existing_comment.text or "",
  }, function(text)
    if not text or text == "" then
      return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local context_lines = diff.get_context(bufnr, line, 3)
    local context = table.concat(context_lines, "\n")

    local data
    local err
    if existing_comment then
      data, err = storage.update_comment(range, existing_comment.id, {
        text = text,
        context = context,
      })
    else
      data, err = storage.add_comment(range, {
        id = storage.generate_id(),
        file = file,
        side = side,
        line = line,
        text = text,
        context = context,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      })
    end

    if not data then
      notify_storage_error(err)
      return
    end

    vim.notify(existing_comment and "Comment updated" or "Comment added", vim.log.levels.INFO)
    session.load_session(range)
  end)
end

---@param range string
---@param comment ReviewComment
---@param list_win integer
---@param refresh fun(selected_id: string)|nil
function M.edit_comment(range, comment, list_win, refresh)
  vim.ui.input({ prompt = "Edit comment: ", default = comment.text }, function(text)
    if not text or text == "" then
      return
    end

    local data, err = storage.update_comment(range, comment.id, { text = text })
    if not data then
      notify_storage_error(err)
      return
    end

    session.load_session(range)
    if refresh then
      refresh(comment.id)
    elseif vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_close(list_win, true)
      require("herdr-review.ui.list").open_list()
    end
  end)
end

return M

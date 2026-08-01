local render = require("review-diff.render")

local M = {}

local annotation_ns = vim.api.nvim_create_namespace("review-diff-annotations")

function M.get_namespace()
  return annotation_ns
end

function M.apply(view)
  local result = { applied = {}, stale = {} }
  for _, side in ipairs({ "left", "right" }) do
    vim.api.nvim_buf_clear_namespace(view[side .. "_buf"], annotation_ns, 0, -1)
  end

  for _, id in ipairs(view.annotation_order) do
    local annotation = view.annotations[id]
    if annotation then
      local row_index, row = view:location_row(annotation.location)
      local side = annotation.location and annotation.location.side
      if row_index and side and row.source_row and row.source_row[side .. "_line"] then
        local bufnr = view[side .. "_buf"]
        local win_width = vim.api.nvim_win_get_width(view[side .. "_win"])
        local lines = render.annotation_lines(annotation.text or "", win_width)
        vim.api.nvim_buf_set_extmark(bufnr, annotation_ns, row_index - 1, 0, {
          virt_lines = lines,
          virt_lines_above = false,
        })

        local other_side = side == "left" and "right" or "left"
        local other_bufnr = view[other_side .. "_buf"]
        local empty = {}
        for _ = 1, #lines do
          table.insert(empty, { { "" } })
        end
        vim.api.nvim_buf_set_extmark(other_bufnr, annotation_ns, row_index - 1, 0, {
          virt_lines = empty,
          virt_lines_above = false,
        })

        table.insert(result.applied, id)
      else
        table.insert(result.stale, id)
      end
    end
  end
  view.annotation_result = result
  return result
end

function M.set_all(view, items)
  view.annotations = {}
  view.annotation_order = {}
  for _, annotation in ipairs(items or {}) do
    if annotation.id then
      local id = tostring(annotation.id)
      view.annotations[id] = vim.deepcopy(annotation)
      table.insert(view.annotation_order, id)
    end
  end
  return M.apply(view)
end

function M.set_one(view, item)
  local id = tostring(item.id)
  if not view.annotations[id] then
    table.insert(view.annotation_order, id)
  end
  view.annotations[id] = vim.deepcopy(item)
  return M.apply(view)
end

function M.remove_one(view, id)
  id = tostring(id)
  view.annotations[id] = nil
  for index, candidate in ipairs(view.annotation_order) do
    if candidate == id then
      table.remove(view.annotation_order, index)
      break
    end
  end
  M.apply(view)
end

function M.clear(view)
  view.annotations = {}
  view.annotation_order = {}
  for _, side in ipairs({ "left", "right" }) do
    vim.api.nvim_buf_clear_namespace(view[side .. "_buf"], annotation_ns, 0, -1)
  end
end

function M.sync(view, items, opts)
  opts = opts or {}
  local resolved_by_id = {}
  local moved_by_id = {}
  local stale_by_id = {}
  local next_annotations = {}
  local radius = opts.radius or view:get_context_radius()

  for _, annotation in ipairs(items or {}) do
    local id = annotation.id and tostring(annotation.id) or nil
    local anchor = annotation.anchor or annotation.location
    if id and anchor then
      local resolved = view:resolve_anchor(anchor, { radius = radius })
      if resolved then
        view:expand_location(resolved)
        resolved_by_id[id] = resolved
        if resolved.line ~= anchor.line then
          local context = view:context(resolved, { radius = radius })
          moved_by_id[id] = {
            location = resolved,
            context = context and context.text or "",
            context_start = context and context.start_line or resolved.line,
          }
        end
        table.insert(next_annotations, {
          id = id,
          location = resolved,
          text = annotation.text,
        })
      else
        stale_by_id[id] = true
        table.insert(next_annotations, {
          id = id,
          location = {
            file = anchor.file,
            side = anchor.side,
            line = nil,
          },
          text = annotation.text,
        })
      end
    end
  end

  view:render()
  local applied_result = M.set_all(view, next_annotations)
  local result = {
    applied = applied_result.applied,
    stale = applied_result.stale,
    resolved = resolved_by_id,
    moved = moved_by_id,
  }
  for id in pairs(stale_by_id) do
    local already_present = false
    for _, stale_id in ipairs(result.stale) do
      if stale_id == id then
        already_present = true
        break
      end
    end
    if not already_present then
      table.insert(result.stale, id)
    end
  end
  table.sort(result.stale)
  return result
end

return M

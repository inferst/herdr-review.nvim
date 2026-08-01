local spec_module = require("herdr-review.spec")

local M = {}

local function hash_parts(parts)
  local encoded = {}
  for _, part in ipairs(parts) do
    part = tostring(part)
    table.insert(encoded, string.format("%d:%s", #part, part))
  end
  return vim.fn.sha256(table.concat(encoded))
end

local STATUS_MAP = {
  A = "added",
  C = "copied",
  D = "deleted",
  M = "modified",
  R = "renamed",
  T = "modified",
  U = "modified",
}

---@param output string
---@return table[]
function M.parse_name_status(output)
  local tokens = vim.split(output or "", "\0", { plain = true, trimempty = true })
  local files = {}
  local index = 1
  while index <= #tokens do
    local status_token = tokens[index]
    local status = STATUS_MAP[status_token:sub(1, 1)] or "modified"
    if status_token:sub(1, 1) == "R" or status_token:sub(1, 1) == "C" then
      table.insert(files, {
        status = status,
        left_path = tokens[index + 1],
        right_path = tokens[index + 2],
      })
      index = index + 3
    else
      local path = tokens[index + 1]
      if path then
        local left_path = path
        local right_path = path
        if status == "added" then
          left_path = nil
        elseif status == "deleted" then
          right_path = nil
        end
        table.insert(files, {
          status = status,
          left_path = left_path,
          right_path = right_path,
        })
      end
      index = index + 2
    end
  end
  return files
end

local function run_git(job, root, args, callback)
  if job.cancelled then
    return
  end
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  job.process = vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if not job.cancelled then
        callback(result)
      end
    end)
  end)
end

local function error_message(result, fallback)
  local message = vim.trim(result.stderr or "")
  return message ~= "" and message or fallback
end

local function read_worktree_file(path)
  local file, open_error = io.open(path, "rb")
  if not file then
    return nil, open_error
  end
  local content = file:read("*a")
  file:close()
  return content, nil
end

local function inspect_content(content, max_bytes, max_lines)
  if not content then
    return { text = nil }
  end
  if content:find("\0", 1, true) then
    return { binary = true }
  end
  if #content > max_bytes then
    return { too_large = true }
  end
  local line_count = 1
  for _ in content:gmatch("\n") do
    line_count = line_count + 1
  end
  if line_count > max_lines then
    return { too_large = true }
  end
  return { text = content }
end

local function load_content(job, root, source, object_id, path, callback)
  if not path then
    callback({ text = nil })
    return
  end
  if source.kind == "worktree" then
    local content, read_error = read_worktree_file(vim.fs.joinpath(root, path))
    if not content then
      callback(nil, read_error or ("Could not read " .. path))
      return
    end
    callback(inspect_content(content, job.max_file_bytes, job.max_file_lines))
    return
  end

  run_git(job, root, { "show", object_id .. ":" .. path }, function(result)
    if result.code ~= 0 then
      callback(nil, error_message(result, "Could not read " .. path))
      return
    end
    callback(inspect_content(result.stdout, job.max_file_bytes, job.max_file_lines))
  end)
end

local function resolve_endpoint(job, root, endpoint, callback)
  if endpoint.kind == "worktree" then
    run_git(job, root, { "rev-parse", "--verify", "HEAD^{commit}" }, function(result)
      if result.code ~= 0 then
        callback(nil, error_message(result, "Could not resolve HEAD"))
        return
      end
      callback(vim.trim(result.stdout), nil)
    end)
    return
  end

  run_git(job, root, { "rev-parse", "--verify", endpoint.name .. "^{commit}" }, function(result)
    if result.code ~= 0 then
      callback(nil, error_message(result, "Could not resolve " .. endpoint.name))
      return
    end
    callback(vim.trim(result.stdout), nil)
  end)
end

local function resolve_files(job, root, spec, head_oid, compare_base_oid, callback)
  local args = { "diff", "--name-status", "-z", "-M", compare_base_oid }
  if spec.head.kind ~= "worktree" then
    table.insert(args, head_oid)
  end
  table.insert(args, "--")

  run_git(job, root, args, function(result)
    if result.code ~= 0 then
      callback(nil, error_message(result, "Could not calculate Git diff"))
      return
    end

    local files = M.parse_name_status(result.stdout)
    if spec.head.kind ~= "worktree" then
      callback(files, nil)
      return
    end

    run_git(job, root, { "ls-files", "--others", "--exclude-standard", "-z" }, function(untracked)
      if untracked.code ~= 0 then
        callback(nil, error_message(untracked, "Could not list untracked files"))
        return
      end
      local known = {}
      for _, file in ipairs(files) do
        known[file.right_path or file.left_path] = true
      end
      for _, path in ipairs(vim.split(untracked.stdout or "", "\0", { plain = true, trimempty = true })) do
        local stat = vim.uv.fs_stat(vim.fs.joinpath(root, path))
        if not known[path] and stat and stat.type == "file" then
          table.insert(files, { status = "added", right_path = path })
        end
      end
      callback(files, nil)
    end)
  end)
end

local function load_file_contents(job, root, spec, base_content_oid, head_oid, files, index, callback)
  if index > #files then
    callback(files, nil)
    return
  end
  local file = files[index]
  local result = vim.deepcopy(file)
  load_content(job, root, spec.base, base_content_oid, file.left_path, function(base_content, base_error)
    if base_error then
      callback(nil, base_error)
      return
    end
    load_content(job, root, spec.head, head_oid, file.right_path, function(head_content, head_error)
      if head_error then
        callback(nil, head_error)
        return
      end
      result.left_text = base_content and base_content.text or nil
      result.right_text = head_content and head_content.text or nil
      result.binary = (base_content and base_content.binary) or (head_content and head_content.binary)
      result.too_large = (base_content and base_content.too_large) or (head_content and head_content.too_large)
      files[index] = result
      load_file_contents(job, root, spec, base_content_oid, head_oid, files, index + 1, callback)
    end)
  end)
end

---@param spec table
---@param opts table|nil
---@param callbacks table
---@return table
function M.resolve(spec, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  local job = {
    cancelled = false,
    max_file_bytes = opts.max_file_bytes or 2 * 1024 * 1024,
    max_file_lines = opts.max_file_lines or 100000,
  }
  function job:cancel()
    self.cancelled = true
    if self.process then
      pcall(function()
        self.process:kill(15)
      end)
    end
  end

  local cwd = opts.cwd or vim.fn.getcwd()
  local ctx = {}

  local function fail(message)
    if callbacks.on_error then
      callbacks.on_error(message)
    end
  end

  -- The resolution runs as a sequence of async steps. Each step derives one
  -- Git fact into `ctx` and calls the next; any failure funnels through `fail`.
  -- Forward-declared so the steps read in execution order, top to bottom.
  local resolve_root, resolve_base, resolve_head, resolve_compare_base, list_files, load_contents, deliver

  function resolve_root()
    run_git(job, cwd, { "rev-parse", "--show-toplevel" }, function(result)
      if result.code ~= 0 then
        return fail(error_message(result, "Not inside a Git repository"))
      end
      ctx.root = vim.trim(result.stdout)
      resolve_base()
    end)
  end

  function resolve_base()
    resolve_endpoint(job, ctx.root, spec.base, function(base_oid, err)
      if err then
        return fail(err)
      end
      ctx.base_oid = base_oid
      resolve_head()
    end)
  end

  function resolve_head()
    resolve_endpoint(job, ctx.root, spec.head, function(head_oid, err)
      if err then
        return fail(err)
      end
      ctx.head_oid = head_oid
      resolve_compare_base()
    end)
  end

  function resolve_compare_base()
    if spec.operator ~= "..." then
      ctx.compare_base_oid = ctx.base_oid
      return list_files()
    end
    run_git(job, ctx.root, { "merge-base", ctx.base_oid, ctx.head_oid }, function(result)
      if result.code ~= 0 then
        return fail(error_message(result, "Could not find merge-base"))
      end
      ctx.compare_base_oid = vim.trim(result.stdout)
      list_files()
    end)
  end

  function list_files()
    resolve_files(job, ctx.root, spec, ctx.head_oid, ctx.compare_base_oid, function(files, err)
      if err then
        return fail(err)
      end
      ctx.files = files
      load_contents()
    end)
  end

  function load_contents()
    load_file_contents(job, ctx.root, spec, ctx.compare_base_oid, ctx.head_oid, ctx.files, 1, function(files, err)
      if err then
        return fail(err)
      end
      ctx.files = files
      deliver()
    end)
  end

  function deliver()
    if not callbacks.on_ready then
      return
    end
    local target_id = spec.head.kind == "worktree" and "WORKTREE" or ctx.head_oid
    callbacks.on_ready({
      cwd = opts.cwd,
      repo_root = ctx.root,
      review_id = hash_parts({ ctx.root, spec.operator, ctx.compare_base_oid, target_id }),
      label = spec_module.label(spec),
      header_left = spec_module.header_side(spec.base),
      header_right = spec_module.header_side(spec.head),
      spec = vim.deepcopy(spec),
      files = ctx.files,
      resolved = {
        base_oid = ctx.base_oid,
        head_oid = ctx.head_oid,
        compare_base_oid = ctx.compare_base_oid,
      },
    })
  end

  resolve_root()
  return job
end

return M

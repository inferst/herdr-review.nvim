local spec_module = require("review-diff.spec")

local M = {}

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
        old_path = tokens[index + 1],
        new_path = tokens[index + 2],
      })
      index = index + 3
    else
      local path = tokens[index + 1]
      if path then
        local old_path = path
        local new_path = path
        if status == "added" then
          old_path = nil
        elseif status == "deleted" then
          new_path = nil
        end
        table.insert(files, {
          status = status,
          old_path = old_path,
          new_path = new_path,
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

local function resolve_files(job, root, spec, old_oid, new_oid, compare_old_oid, callback)
  local args = { "diff", "--name-status", "-z", "-M", compare_old_oid }
  if spec.new.kind ~= "worktree" then
    table.insert(args, new_oid)
  end
  table.insert(args, "--")

  run_git(job, root, args, function(result)
    if result.code ~= 0 then
      callback(nil, error_message(result, "Could not calculate Git diff"))
      return
    end

    local files = M.parse_name_status(result.stdout)
    if spec.new.kind ~= "worktree" then
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
        known[file.new_path or file.old_path] = true
      end
      for _, path in ipairs(vim.split(untracked.stdout or "", "\0", { plain = true, trimempty = true })) do
        local stat = vim.uv.fs_stat(vim.fs.joinpath(root, path))
        if not known[path] and stat and stat.type == "file" then
          table.insert(files, { status = "added", new_path = path })
        end
      end
      callback(files, nil)
    end)
  end)
end

local function load_file_contents(job, root, spec, old_content_oid, new_oid, files, index, callback)
  if index > #files then
    callback(files, nil)
    return
  end
  local file = files[index]
  local result = vim.deepcopy(file)
  load_content(job, root, spec.old, old_content_oid, file.old_path, function(old_content, old_error)
    if old_error then
      callback(nil, old_error)
      return
    end
    load_content(job, root, spec.new, new_oid, file.new_path, function(new_content, new_error)
      if new_error then
        callback(nil, new_error)
        return
      end
      result.old_text = old_content and old_content.text or nil
      result.new_text = new_content and new_content.text or nil
      result.binary = (old_content and old_content.binary) or (new_content and new_content.binary)
      result.too_large = (old_content and old_content.too_large) or (new_content and new_content.too_large)
      files[index] = result
      load_file_contents(job, root, spec, old_content_oid, new_oid, files, index + 1, callback)
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
  run_git(job, cwd, { "rev-parse", "--show-toplevel" }, function(root_result)
    if root_result.code ~= 0 then
      if callbacks.on_error then
        callbacks.on_error(error_message(root_result, "Not inside a Git repository"))
      end
      return
    end
    local root = vim.trim(root_result.stdout)
    resolve_endpoint(job, root, spec.old, function(old_oid, old_error)
      if old_error then
        if callbacks.on_error then
          callbacks.on_error(old_error)
        end
        return
      end
      resolve_endpoint(job, root, spec.new, function(new_oid, new_error)
        if new_error then
          if callbacks.on_error then
            callbacks.on_error(new_error)
          end
          return
        end

        local function finish(compare_old_oid)
          resolve_files(job, root, spec, old_oid, new_oid, compare_old_oid, function(files, files_error)
            if files_error then
              if callbacks.on_error then
                callbacks.on_error(files_error)
              end
              return
            end
            load_file_contents(job, root, spec, compare_old_oid, new_oid, files, 1, function(loaded_files, load_error)
              if load_error then
                if callbacks.on_error then
                  callbacks.on_error(load_error)
                end
                return
              end
              local target_id = spec.new.kind == "worktree" and "WORKTREE" or new_oid
              local review_id = vim.fn.sha256(table.concat({ root, spec.operator, compare_old_oid, target_id }, "\0"))
              if callbacks.on_ready then
                callbacks.on_ready({
                  cwd = opts.cwd,
                  repo_root = root,
                  review_id = review_id,
                  label = spec_module.label(spec),
                  spec = vim.deepcopy(spec),
                  files = loaded_files,
                  resolved = {
                    old_oid = old_oid,
                    new_oid = new_oid,
                    compare_old_oid = compare_old_oid,
                  },
                })
              end
            end)
          end)
        end

        if spec.operator ~= "..." then
          finish(old_oid)
          return
        end
        run_git(job, root, { "merge-base", old_oid, new_oid }, function(base_result)
          if base_result.code ~= 0 then
            if callbacks.on_error then
              callbacks.on_error(error_message(base_result, "Could not find merge-base"))
            end
            return
          end
          finish(vim.trim(base_result.stdout))
        end)
      end)
    end)
  end)
  return job
end

return M

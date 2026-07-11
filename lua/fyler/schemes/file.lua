local libpath = Fyler.import('fyler.lib.path')
local async = Fyler.import('fyler.lib.async')

local M = {}
local H = {}

local uv = {}
for _, name in ipairs({
  'fs_close',
  'fs_closedir',
  'fs_copyfile',
  'fs_mkdir',
  'fs_open',
  'fs_opendir',
  'fs_readdir',
  'fs_realpath',
  'fs_rename',
  'fs_rmdir',
  'fs_stat',
  'fs_unlink',
}) do
  uv[name] = async.wrap(vim.uv[name])
end

local msg_hints = {
  EEXIST = 'already exists',
  ENOENT = 'does not exist',
  EACCES = 'permission denied',
  ENOTDIR = 'not a directory',
  EISDIR = 'is a directory',
  ENOTEMPTY = 'is not empty',
  ENOSPC = 'not enough disk space',
  EROFS = 'filesystem is read-only',
  EXDEV = 'cannot move across filesystems',
}

local function build_simple_msg(err)
  local code, path = tostring(err):match('(%u+): [^:]+: (.+)$')
  if not code then return tostring(err) end
  return path .. ' ' .. (msg_hints[code] or code)
end

local fs = function(name, ...)
  local err, result = uv[name](...)
  if err then error(('%s: %s'):format(name, err)) end
  return result
end

H.delete_recursive = function(path)
  local dir = fs('fs_opendir', libpath.to_os(path))
  while true do
    local chunk = fs('fs_readdir', dir)
    if not chunk then break end
    for _, entry in ipairs(chunk) do
      local entry_path = libpath.do_join(path, entry.name)
      local entry_type = entry.type
      if entry_type == 'link' then entry_type = fs('fs_stat', libpath.to_os(entry_path)).type end
      if entry_type == 'directory' then
        H.delete_recursive(entry_path)
      else
        fs('fs_unlink', libpath.to_os(entry_path))
      end
    end
  end
  fs('fs_closedir', dir)
  fs('fs_rmdir', libpath.to_os(path))
end

H.copy_recursive = function(src, dst)
  fs('fs_mkdir', libpath.to_os(dst), 493)
  local dir = fs('fs_opendir', libpath.to_os(src))
  while true do
    local chunk = fs('fs_readdir', dir)
    if not chunk then break end
    for _, entry in ipairs(chunk) do
      local entry_src = libpath.do_join(src, entry.name)
      local entry_dst = libpath.do_join(dst, entry.name)
      local entry_type = entry.type
      if entry_type == 'link' then entry_type = fs('fs_stat', libpath.to_os(entry_src)).type end
      if entry_type == 'directory' then
        H.copy_recursive(entry_src, entry_dst)
      else
        fs('fs_copyfile', libpath.to_os(entry_src), libpath.to_os(entry_dst), 0)
      end
    end
  end
  fs('fs_closedir', dir)
end

H.fs_create = function(dst)
  if vim.endswith(dst, '/') then
    fs('fs_mkdir', libpath.to_os(dst), 493)
  else
    local fd = fs('fs_open', libpath.to_os(dst), 'w', 420)
    fs('fs_close', fd)
  end
end

H.fs_delete = function(src)
  local stat = fs('fs_stat', libpath.to_os(src))
  if stat.type == 'directory' then
    H.delete_recursive(src)
  else
    fs('fs_unlink', libpath.to_os(src))
  end
end

H.fs_move = function(src, dst) fs('fs_rename', libpath.to_os(src), libpath.to_os(dst)) end

H.fs_copy = function(src, dst)
  local stat = fs('fs_stat', libpath.to_os(src))
  if stat.type == 'directory' then
    H.copy_recursive(src, dst)
  else
    fs('fs_copyfile', libpath.to_os(src), libpath.to_os(dst), 0)
  end
end

M.fs_is_dir = function(path) return vim.fn.isdirectory(libpath.to_normalize(path)) == 1 end

M.fs_scan_dir = function(path, cb)
  assert(path, 'Expected string got nil')
  async.run(function()
    local dir = fs('fs_opendir', libpath.to_os(path))
    local entries = {}
    while true do
      local chunk = fs('fs_readdir', dir)
      if not chunk then break end
      vim.list_extend(entries, chunk)
    end
    for _, entry in ipairs(entries) do
      entry.path = libpath.do_join(path, entry.name)
      entry.full_path = entry.path
      if entry.type == 'link' then
        local stat_err, stat = uv.fs_stat(entry.path)
        if not stat_err then
          entry.type = stat.type
          local rp_err, rp = uv.fs_realpath(entry.path)
          if not rp_err then
            entry.link = rp
            entry.link_target = entry.link
          end
        end
      end
    end
    fs('fs_closedir', dir)
    cb(nil, entries)
  end, function(err)
    if err then cb(build_simple_msg(err), nil) end
  end)
end

local action_handlers = {
  create = function(a) H.fs_create(a.dst) end,
  delete = function(a) H.fs_delete(a.src) end,
  move = function(a) H.fs_move(a.src, a.dst) end,
  copy = function(a) H.fs_copy(a.src, a.dst) end,
}

M.fs_mutate = function(actions, cb)
  -- Collect the src paths of all directory moves so we can skip their children below
  local folder_move_srcs = {}
  for _, action in ipairs(actions) do
    if action.name == 'move' and action.src then
      local s = action.src:gsub('[/\\]+$', '')
      local stat = vim.uv.fs_stat(s)
      if stat and stat.type == 'directory' then
        folder_move_srcs[s] = true
      end
    end
  end

  local filtered_actions = {}
  for _, action in ipairs(actions) do
    if action.src then action.src = action.src:gsub('[/\\]+$', '') end
    if action.dst then action.dst = action.dst:gsub('[/\\]+$', '') end

    local skip = false
    if action.name == 'move' then
      -- Skip child moves whose parent folder is also being moved in this batch.
      -- OS rename of a directory already carries all children atomically.
      for folder_src in pairs(folder_move_srcs) do
        if action.src ~= folder_src
          and action.src:sub(1, #folder_src + 1) == folder_src .. '/' then
          skip = true
          break
        end
      end
      -- Also skip if src is gone but dst already exists (race / duplicate)
      if not skip then
        local src_ok = vim.uv.fs_stat(action.src) ~= nil
        local dst_ok = vim.uv.fs_stat(action.dst) ~= nil
        if not src_ok and dst_ok then
          skip = true
        end
      end
    elseif action.name == 'delete' then
      if not vim.uv.fs_stat(action.src) then
        skip = true
      end
    end
    if not skip then
      table.insert(filtered_actions, action)
    end
  end

  local current_action
  async.run(function()
    for _, action in ipairs(filtered_actions) do
      current_action = action
      local handler = action_handlers[action.name]
      if handler then handler(action) end
    end
  end, function(err)
    if err then
      cb('Failed to ' .. current_action.name .. ': ' .. build_simple_msg(err))
    else
      cb(nil)
    end
  end)
end

return M

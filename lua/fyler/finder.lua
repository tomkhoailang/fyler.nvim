local config = Fyler.import('fyler.config')
local extensions = Fyler.import('fyler.extensions')
local icon = Fyler.import('fyler.integrations.icon')
local input = Fyler.import('fyler.input')
local libfs = Fyler.import('fyler.lib.fs')
local libpath = Fyler.import('fyler.lib.path')
local libui = Fyler.import('fyler.lib.ui')
local state = Fyler.import('fyler.state')
local util = Fyler.import('fyler.util')

local function parse_indent(line)
  local depth = 0
  local offset = 1
  while true do
    local sub2 = line:sub(offset, offset + 1)
    if sub2 == "  " then
      depth = depth + 1
      offset = offset + 2
    else
      local sub4 = line:sub(offset, offset + 3)
      if sub4 == "│ " then
        depth = depth + 1
        offset = offset + 4
      else
        local sub6 = line:sub(offset, offset + 5)
        if sub6 == "└╴" or sub6 == "├╴" then
          depth = depth + 1
          offset = offset + 6
        else
          break
        end
      end
    end
  end
  return depth, line:sub(offset)
end

---@class fyler.FSEntry
---@field path string
---@field id integer
---@field link string|nil
---@field name string
---@field type string

---@class fyler.Finder
---@field private _view table
---@field private _refresh_count integer|nil
---@field private _is_refreshing boolean
---@field private _pending_refresh table|nil
---@field private _current_refresh_args table|nil
---@field private _id_to_line table|nil
---@field buf_id integer|nil
---@field cache table
---@field opts fyler.FinderOpts
---@field state fyler.FinderState
---@field win_id integer|nil

---@class fyler.FinderOpts : fyler.WindowConfig, fyler.Config
---@field scheme string|nil
---@field root_path string|nil

---@class fyler.WindowConfig : vim.api.keyset.win_config
---@field col integer|fyler.FinderWindowAlignment|nil
---@field height integer|string|nil
---@field kind fyler.FinderWindowKind
---@field row integer|fyler.FinderWindowAlignment|nil
---@field width integer|string|nil

---@alias fyler.FinderWindowKind
---| 'floating'
---| 'replace'
---| 'split_above'
---| 'split_above_all'
---| 'split_below'
---| 'split_below_all'
---| 'split_left'
---| 'split_left_most'
---| 'split_right'
---| 'split_right_most'

---@alias fyler.FinderScheme
---| 'file'
---| 'scp'

---@alias fyler.FinderWindowAlignment
---| 'center'
---| 'end'
---| 'start'

---@class fyler.Action
---@field name 'create'|'delete'|'move'|'copy'
---@field src string|nil
---@field dst string|nil

local M = {}
local H = {}

---@type table<integer, fyler.Finder>
local instances = {}

M.clipboard = {
  action = nil,
  items = {},
  deleted = {},
}

local function is_dir_empty(instance, path)
  if instance and instance._parent_has_children_in_buffer and instance._parent_has_children_in_buffer[path] then
    return false
  end

  local uv = vim.uv or vim.loop
  local handle = uv.fs_scandir(path)
  if not handle then return true end
  while true do
    local name, _ = uv.fs_scandir_next(handle)
    if not name then break end
    local child_path = path .. '/' .. name
    if not M.clipboard.deleted[child_path] then
      return false
    end
  end
  return true
end

---@class fyler.Finder
local Finder = {}

---@private
---@param instance fyler.Finder
---@return string
---@nodiscard
H.buffer_name = function(instance)
  local scheme_name = instance.opts.scheme
  local pseudo_root_path = instance.state.pseudo_root_path
  return ('fyler-%s://%s'):format(scheme_name, pseudo_root_path)
end

---@private
---@param order integer[]
---@param fs_actions fyler.Action[]
---@param pseudo_root_path string
---@return table, table
H.build_action_confirmation_ui = function(order, fs_actions, pseudo_root_path)
  local action_name_components = {}
  local action_args_components = {}
  for _, i in ipairs(order) do
    local fs_action = fs_actions[i]
    if fs_action.name == 'create' then
      action_hl = 'DiagnosticInfo'
    elseif fs_action.name == 'delete' or fs_action.name == 'trash' then
      action_hl = 'DiagnosticError'
    elseif fs_action.name == 'move' then
      action_hl = 'DiagnosticWarn'
    elseif fs_action.name == 'copy' then
      action_hl = 'DiagnosticHint'
    end

    local args_row
    if fs_action.name == 'delete' or fs_action.name == 'trash' then
      args_row = { tag = 'text', value = libpath.to_rel(pseudo_root_path, fs_action.src), hl = 'Comment' }
    elseif fs_action.name == 'create' then
      args_row = { tag = 'text', value = libpath.to_rel(pseudo_root_path, fs_action.dst) }
    else
      local src_rel = libpath.to_rel(pseudo_root_path, fs_action.src or '')
      local dst_rel = libpath.to_rel(pseudo_root_path, fs_action.dst)
      args_row = {
        tag = 'row',
        children = {
          { tag = 'text', value = src_rel, hl = 'Comment' },
          { tag = 'text', value = ' -> ' },
          { tag = 'text', value = dst_rel },
        },
      }
    end
    table.insert(action_name_components, {
      tag = 'text',
      value = fs_action.name:gsub('^%l', string.upper),
      hl = action_hl,
    })
    table.insert(action_args_components, args_row)
  end
  local composed = libui.compose({
    tag = 'col',
    children = {
      {
        tag = 'row',
        children = {
          { tag = 'col', children = action_name_components },
          {
            tag = 'col',
            children = vim
              .iter(order)
              :map(function() return { tag = 'text', value = ' │ ', hl = 'FloatBorder' } end)
              :totable(),
          },
          { tag = 'col', children = action_args_components },
        },
      },
    },
  })
  return composed.lines, composed.highlights
end

---@param fs_actions fyler.Action[]
---@param pseudo_root_path string
---@param errors string[]
---@return table
---@return table
H.build_action_dependency_graph = function(fs_actions, pseudo_root_path, errors)
  local trie_root = { children = {} }

  vim.iter(fs_actions):each(function(action)
    local splitted_path =
      libpath.do_split(libpath.to_rel(pseudo_root_path, action.name == 'create' and action.dst or action.src))
    local current_node = trie_root
    for i = 1, #splitted_path do
      if not current_node.children[splitted_path[i]] then
        current_node.children[splitted_path[i]] = { children = {} }
      end
      current_node = current_node.children[splitted_path[i]]
    end
    current_node.value = current_node.value or {}
    table.insert(current_node.value, action)
  end)

  local fs_action_indicies = {}
  for i, fs_action in ipairs(fs_actions) do
    local action_key = H.build_fs_action_id(fs_action)
    if not fs_action_indicies[action_key] then fs_action_indicies[action_key] = i end
  end

  local graph = {}
  local in_degree = {}
  for i = 1, #fs_actions do
    graph[i] = {}
    in_degree[i] = 0
  end

  local edge_add = function(u, v)
    local u_index = fs_action_indicies[H.build_fs_action_id(u)]
    local v_index = fs_action_indicies[H.build_fs_action_id(v)]
    table.insert(graph[v_index], u_index)
    in_degree[u_index] = in_degree[u_index] + 1
  end

  local queue = { trie_root }
  local fs_action_parents = {}
  while #queue > 0 do
    local current_node = table.remove(queue, 1)

    local fs_action_siblings = {}
    for _, child in pairs(current_node.children) do
      vim.list_extend(fs_action_siblings, child.value or {})
    end

    vim.iter(fs_action_siblings):each(function(sibling)
      vim.iter(fs_action_parents):each(function(parent)
        if parent.name == 'create' then
          edge_add(sibling, parent)
        else
          edge_add(parent, sibling)
        end
      end)
    end)

    vim.iter(fs_action_siblings):each(function(sr)
      vim.iter(fs_action_siblings):each(function(sl) H.handle_action_pair(sl, sr, edge_add, errors) end)
    end)

    for _, child in pairs(current_node.children) do
      table.insert(queue, child)
    end

    vim.list_extend(fs_action_parents, fs_action_siblings)
  end

  return graph, in_degree
end

---@private
---@param fs_action fyler.Action
---@return string
---@nodiscard
H.build_fs_action_id = function(fs_action)
  return string.format('%s | %s | %s', fs_action.name, fs_action.src, fs_action.dst)
end

---@private
---@return table, integer
H.build_fs_entry_ui = function(instance, item)
  local entry_state = item.type == 'directory' and { expanded = item.expanded } or nil
  local icon_char, icon_hl = icon.get(item.type, item.path, entry_state)
  local children = {}
  local name_col = 0
  if item.depth > 0 then
    for i = 1, item.depth do
      table.insert(children, { tag = 'text', value = '│ ', hl = 'SnacksIndent' })
    end
    name_col = name_col + item.depth * 2
  end

  if not icon_char or icon_char == "" then
    if item.type == 'directory' then
      local is_empty = is_dir_empty(instance, item.path)
      if is_empty then
        icon_char = item.expanded and '' or ''
      else
        icon_char = item.expanded and '' or ''
      end
      icon_hl = 'FylerDirectoryName'
    else
      icon_char = ''
      icon_hl = 'FylerNormal'
    end
  end

  if icon_char and #icon_char > 0 then
    table.insert(children, { tag = 'text', value = icon_char, hl = icon_hl })
    table.insert(children, { tag = 'text', value = ' ' })
    name_col = name_col + #icon_char + 1
  end

  local id_part = string.format('/%0' .. math.ceil(math.log10(state.store_next_id)) .. 'd ', item.id)
  table.insert(children, { tag = 'text', value = id_part })
  name_col = name_col + #id_part
  table.insert(children, {
    tag = 'text',
    value = item.name,
    hl = item.type == 'directory' and 'FylerDirectoryName' or 'FylerNormal',
  })
  return children, name_col
end

---@param instance fyler.Finder
---@param id_to_path table<integer, string>
---@param buf_lines string[]
---@return fyler.Action[], string[]
H.compute_fs_actions = function(instance, id_to_path, buf_lines)
  local preprocessed_lines = {}
  for _, line in ipairs(buf_lines) do
    local content = line:gsub("│ ", ""):gsub("%s+", "")
    if content ~= "" then
      local clean_line = line:gsub("│ ", "  ")
      table.insert(preprocessed_lines, clean_line)
    end
  end

  for i = 1, #preprocessed_lines - 1 do
    local current_line = preprocessed_lines[i]
    local next_line = preprocessed_lines[i + 1]

    if current_line:match("%S") and next_line:match("%S") then
      local is_new = current_line:match('/%d+') == nil
      local current_depth, current_content = parse_indent(current_line)
      local next_depth, _ = parse_indent(next_line)
      local ends_with_slash = current_content:match("[/\\]%s*$") ~= nil

      if is_new and next_depth > current_depth and not ends_with_slash then
        local content, trailing = current_line:match("^(.-)(%s*)$")
        preprocessed_lines[i] = content .. "/" .. trailing
      end
    end
  end

  local seen_ids = {}
  local stack = { { path = instance.state.pseudo_root_path, depth = -1 } }

  local fs_actions = {}
  local transitions = {}
  local errors = {}
  vim.iter(preprocessed_lines):each(function(buf_line)
    local id, name, depth, is_dir = H.parse_buf_line(buf_line)
    while #stack > 1 and stack[#stack].depth >= depth do
      table.remove(stack)
    end

    local parent_path = stack[#stack].path
    local path = libpath.do_join(parent_path, name)
    if id then
      transitions[id] = transitions[id] or {}
      table.insert(transitions[id], path)
      seen_ids[id] = true
      if is_dir then
        table.insert(stack, { path = path:sub(1, -2), depth = depth })
      elseif state.store[id] and state.store[id].type == 'directory' then
        table.insert(stack, { path = state.store[id].path, depth = depth })
      end
    else
      local segments = libpath.do_split(name)
      local current_path = parent_path
      for j = 1, #segments do
        local segment = segments[j]
        local is_last = j == #segments
        local segment_path = libpath.do_join(current_path, segment)
        if is_last then
          table.insert(fs_actions, { name = 'create', dst = segment_path .. (is_dir and '/' or '') })
        else
          table.insert(fs_actions, { name = 'create', dst = segment_path .. '/' })
          current_path = segment_path .. '/'
        end
      end
      if is_dir then table.insert(stack, { path = libpath.do_join(parent_path, name), depth = depth }) end
    end
  end)

  for id, path in pairs(id_to_path) do
    if not seen_ids[id] then table.insert(fs_actions, { name = 'delete', src = path }) end
  end

  for id, transition in pairs(transitions) do
    local keep_original = vim.tbl_contains(transition, id_to_path[id])
    for i, new_path in ipairs(transition) do
      if new_path ~= id_to_path[id] then
        if keep_original or i < #transition then
          table.insert(fs_actions, { name = 'copy', src = id_to_path[id], dst = new_path })
        else
          table.insert(fs_actions, { name = 'move', src = id_to_path[id], dst = new_path })
        end
      end
    end
  end

  local function normalize_path(p)
    if not p then return "" end
    p = libpath.to_os(p):gsub("\\", "/")
    p = p:gsub("/+$", "")
    return p
  end

  local function is_subpath(parent, child)
    local n_parent = normalize_path(parent) .. "/"
    local n_child = normalize_path(child) .. "/"
    return n_child:sub(1, #n_parent) == n_parent
  end

  local function scan_dir_recursive(dir_path)
    local paths = {}
    local function scan(p)
      local handle = vim.uv.fs_scandir(p)
      if handle then
        while true do
          local name, type = vim.uv.fs_scandir_next(handle)
          if not name then break end
          local full = p .. "/" .. name
          table.insert(paths, full)
          if type == "directory" then
            scan(full)
          end
        end
      end
    end
    scan(libpath.to_os(dir_path))
    return paths
  end

  -- Identify parent moves
  local move_map = {}
  for _, action in ipairs(fs_actions) do
    if action.name == "move" then
      local stat = vim.uv.fs_stat(libpath.to_os(action.src))
      if stat and stat.type == "directory" then
        table.insert(move_map, action)
      end
    end
  end

  -- Clean deletes that are children of moved folders
  local fs_actions_clean = {}
  for _, action in ipairs(fs_actions) do
    local keep = true
    if action.name == "delete" then
      for _, move in ipairs(move_map) do
        if is_subpath(move.src, action.src) then
          keep = false
          break
        end
      end
    end
    if keep then
      table.insert(fs_actions_clean, action)
    end
  end
  fs_actions = fs_actions_clean

  -- Scan and append extra move actions for child files/folders of moved folders
  local extra_moves = {}
  local existing_move_dsts = {}
  for _, action in ipairs(fs_actions) do
    if action.name == "move" then
      existing_move_dsts[normalize_path(action.dst)] = true
    end
  end

  for _, move in ipairs(move_map) do
    local child_paths = scan_dir_recursive(move.src)
    local norm_src = normalize_path(move.src)
    for _, child_src in ipairs(child_paths) do
      local norm_child_src = normalize_path(child_src)
      local rel = norm_child_src:sub(#norm_src + 2)
      local child_dst = move.dst .. "/" .. rel
      
      if not existing_move_dsts[normalize_path(child_dst)] then
        table.insert(extra_moves, {
          name = "move",
          src = child_src,
          dst = child_dst
        })
        existing_move_dsts[normalize_path(child_dst)] = true
      end
    end
  end

  for _, action in ipairs(extra_moves) do
    table.insert(fs_actions, action)
  end

  -- Identify parent deletes
  local delete_dirs = {}
  for _, action in ipairs(fs_actions) do
    if action.name == "delete" then
      local stat = vim.uv.fs_stat(libpath.to_os(action.src))
      if stat and stat.type == "directory" then
        if action.src ~= instance.state.pseudo_root_path then
          table.insert(delete_dirs, action.src)
        end
      end
    end
  end

  -- Scan and append extra delete actions for child files/folders of deleted folders
  local extra_deletes = {}
  local existing_delete_srcs = {}
  for _, action in ipairs(fs_actions) do
    if action.name == "delete" then
      existing_delete_srcs[normalize_path(action.src)] = true
    end
  end

  for _, parent_dir in ipairs(delete_dirs) do
    local child_paths = scan_dir_recursive(parent_dir)
    for _, child_src in ipairs(child_paths) do
      if not existing_delete_srcs[normalize_path(child_src)] then
        table.insert(extra_deletes, {
          name = "delete",
          src = child_src
        })
        existing_delete_srcs[normalize_path(child_src)] = true
      end
    end
  end

  for _, action in ipairs(extra_deletes) do
    table.insert(fs_actions, action)
  end

  -- Track which paths have delete actions
  local delete_map = {}
  for _, action in ipairs(fs_actions) do
    if action.name == "delete" then
      local norm_path = normalize_path(action.src)
      delete_map[norm_path] = action
    end
  end

  -- First pass: identify cancellations (delete + create of same type)
  local cancelled = {}
  for _, action in ipairs(fs_actions) do
    if action.name == "create" then
      local norm_path = normalize_path(action.dst)
      local matching_delete = delete_map[norm_path]
      if matching_delete then
        local stat = vim.uv.fs_stat(norm_path)
        local is_delete_dir = stat and stat.type == "directory"
        local is_create_dir = action.dst:match("[/\\]$") ~= nil
        
        if is_delete_dir == is_create_dir then
          cancelled[action] = true
          cancelled[matching_delete] = true
        end
      end
    end
  end

  -- Second pass: build filtered actions list
  local filtered_actions = {}
  for _, action in ipairs(fs_actions) do
    if not cancelled[action] then
      local keep = true
      if action.name == "create" then
        local norm_path = normalize_path(action.dst)
        if vim.uv.fs_stat(norm_path) and not delete_map[norm_path] then
          keep = false
        end
      end
      if keep then
        table.insert(filtered_actions, action)
      end
    end
  end

  if #filtered_actions == 0 and #fs_actions > 0 then
    vim.schedule(function()
      instance:refresh({ recursive = true })
    end)
  end

  local seen = {}
  filtered_actions = vim
    .iter(filtered_actions)
    :filter(function(fs_action)
      if seen[H.build_fs_action_id(fs_action)] then return false end
      seen[H.build_fs_action_id(fs_action)] = true
      return true
    end)
    :totable()

  return filtered_actions, errors
end

---@private
H.finish_refresh = function(instance)
  if instance._view.lnum then
    vim.fn.winrestview({ lnum = instance._view.lnum, col = 0 })
    instance._view = {}
  end

  instance._is_refreshing = false
  instance._refresh_count = (instance._refresh_count or 0) + 1

  if instance._pending_refresh then
    local args = instance._pending_refresh
    instance._pending_refresh = nil
    instance:refresh(args)
  end
end

---@private
---@param existing table|nil
---@param incoming table|nil
---@return table|nil
H.merge_refresh_args = function(existing, incoming)
  if not existing then return incoming end
  if not incoming then return existing end

  local target_path
  if existing.target_path and incoming.target_path then
    target_path = libpath.common_ancestor(existing.target_path, incoming.target_path)
  end

  return {
    callback = H.chain_callbacks(existing.callback, incoming.callback),
    force = existing.force or incoming.force,
    recursive = existing.recursive or incoming.recursive,
    target_path = target_path,
  }
end

---@private
---@param cb_a function|nil
---@param cb_b function|nil
---@return function|nil
H.chain_callbacks = function(cb_a, cb_b)
  if cb_a and cb_b then
    return function()
      cb_a()
      cb_b()
    end
  end
  return cb_a or cb_b
end

---@private
---@param left fyler.Action
---@param right fyler.Action
---@param edge_add fun(u: fyler.Action, v: fyler.Action)
---@param errors string[]
H.handle_action_pair = function(left, right, edge_add, errors)
  if H.build_fs_action_id(left) == H.build_fs_action_id(right) then return end
  if H.build_fs_action_id(left) > H.build_fs_action_id(right) then return end

  local P = { create = 1, delete = 2, copy = 3, move = 4 }
  local function sorted_pair()
    if P[left.name] < P[right.name] then return left, right end
    return right, left
  end

  local first, second = sorted_pair()
  if first.name == 'create' and second.name == 'delete' then
    edge_add(first, second)
  elseif first.name == 'create' and second.name == 'copy' then
    if first.dst == second.src or first.dst == second.dst then
      table.insert(errors, ('Conflict: create %s clashes with copy %s -> %s'):format(first.dst, second.src, second.dst))
    end
  elseif first.name == 'create' and second.name == 'move' then
    if first.dst == second.dst then
      table.insert(errors, ('Conflict: create %s clashes with move %s -> %s'):format(first.dst, second.src, second.dst))
    else
      edge_add(first, second)
    end
  elseif first.name == 'delete' and second.name == 'copy' then
    if first.src == second.src or first.src == second.dst then
      table.insert(errors, ('Conflict: delete %s clashes with copy %s -> %s'):format(first.src, second.src, second.dst))
    end
  elseif first.name == 'delete' and second.name == 'move' then
    if first.src == second.dst then
      table.insert(errors, ('Conflict: delete %s clashes with move %s -> %s'):format(first.src, second.src, second.dst))
    else
      edge_add(first, second)
    end
  elseif first.name == 'copy' and second.name == 'move' then
    if first.dst == second.dst then
      table.insert(
        errors,
        ('Conflict: copy %s -> %s clashes with move %s -> %s'):format(first.src, first.dst, second.src, second.dst)
      )
    else
      edge_add(second, first)
    end
  elseif first.name == 'create' and second.name == 'create' then
    if first.dst == second.dst then table.insert(errors, ('Conflict: create %s appears twice'):format(first.dst)) end
  elseif first.name == 'delete' and second.name == 'delete' then
    if first.src == second.src then table.insert(errors, ('Conflict: delete %s appears twice'):format(first.src)) end
  elseif first.name == 'copy' and second.name == 'copy' then
    if first.dst == second.dst then
      table.insert(
        errors,
        ('Conflict: copy %s -> %s clashes with copy %s -> %s'):format(first.src, first.dst, second.src, second.dst)
      )
    end
  elseif first.name == 'move' and second.name == 'move' then
    if first.dst == second.dst or first.src == second.src then
      table.insert(
        errors,
        ('Conflict: move %s -> %s clashes with move %s -> %s'):format(first.src, first.dst, second.src, second.dst)
      )
    elseif first.dst == second.src then
      edge_add(first, second)
    end
    if second.dst == first.src then edge_add(second, first) end
  end
end

---@param opts fyler.FinderOpts
---@return fyler.Finder
H.new_instance = function(opts)
  local instance = {
    _view = {},
    _is_refreshing = false,
    _refresh_count = nil,
    _pending_refresh = nil,
    _id_to_line = nil,
    cache = {
      ui = {
        indent_guides = opts.ui.indent_guides,
        hidden_items = vim.tbl_deep_extend('force', opts.ui.hidden_items, {
          switches = util.list_to_dict(opts.ui.hidden_items.switches),
          patterns = util.list_to_dict(opts.ui.hidden_items.patterns),
        }),
      },
    },
    opts = opts,
    state = state.new(opts.root_path, opts.scheme),
  }
  setmetatable(instance, { __index = Finder })
  return instance
end

---@param opts table|nil
---@return fyler.FinderOpts
---@nodiscard
H.normalize_opts = function(opts)
  opts = opts or {}
  opts.root_path = libpath.to_normalize(opts.root_path or vim.fn.getcwd(-1, -1))
  opts.scheme = opts.scheme or 'file'
  return config.get_config(opts)
end



---@private
---@param buf_line string
---@return integer|nil
---@return string
---@return integer
---@return boolean
H.parse_buf_line = function(buf_line)
  local id = buf_line:match('/(%d+)')
  local depth, cleaned_line = parse_indent(buf_line)
  buf_line = cleaned_line
  if id then
    local name = buf_line:match('/%d+ (.*)$')
    local id_int = tonumber(id, 10)
    return id_int, name, depth, vim.endswith(name, '/')
  end
  return nil, buf_line, depth, vim.endswith(buf_line, '/')
end

---@private
---@return table, integer, table
-- Get indentation depth of a line
local function get_line_depth(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local count = 0
  for _ in line:gmatch("│ ") do
    count = count + 1
  end
  return count
end

-- Reconstruct path for a buffer line (handles unpersisted files/directories/renames)
local function get_path_for_line(inst, lnum)
  if lnum == 1 then
    return inst.state.pseudo_root_path:gsub("[/\\]+$", ""), true
  end
  local bufnr = inst.buf_id
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  
  -- Determine if it is a directory from its concealed ID or trailing slash
  local has_id_dir = false
  local id = line:match("/(%d+)")
  if id then
    local entry = state.store[tonumber(id)]
    if entry then
      has_id_dir = entry.type == "directory"
    end
  end

  local count = get_line_depth(bufnr, lnum)
  local content = line:sub(count * 4 + 1)
  
  -- Extract name by stripping concealed ID prefix and any preceding icons/spaces
  local name
  if id then
    name = content:match("/%d+%s+(.*)$") or content:match("/%d+$") or content
  else
    name = content
  end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  
  local is_dir = false
  if name ~= "" then
    local has_slash = line:match("[/\\]%s*$") ~= nil or name:match("[/\\]%s*$") ~= nil
    is_dir = has_slash or has_id_dir
    
    if has_slash then
      name = name:gsub("[/\\]%s*$", "")
    end
  else
    is_dir = true
  end

  if name == "" then
    if id then
      is_dir = has_id_dir
      if count == 0 then
        local p = inst.state.pseudo_root_path:gsub("[/\\]+$", "")
        return p, is_dir
      else
        for p = lnum - 1, 1, -1 do
          local p_count = get_line_depth(bufnr, p)
          if p_count == count - 1 then
            local parent_path, _ = get_path_for_line(inst, p)
            local res = parent_path:gsub("[/\\]+$", "")
            return res, is_dir
          end
        end
      end
    end
    local p = inst.state.pseudo_root_path:gsub("[/\\]+$", "")
    return p, true
  end

  if count == 0 then
    local path = libpath.do_join(inst.state.pseudo_root_path, name)
    return path:gsub("[/\\]+$", ""), is_dir
  end

  -- Find parent line (first line above with depth = count - 1)
  for p = lnum - 1, 1, -1 do
    local p_count = get_line_depth(bufnr, p)
    if p_count == count - 1 then
      local parent_path, _ = get_path_for_line(inst, p)
      local path = libpath.do_join(parent_path, name)
      return path:gsub("[/\\]+$", ""), is_dir
    end
  end

  local path = libpath.do_join(inst.state.pseudo_root_path, name)
  return path:gsub("[/\\]+$", ""), is_dir
end

local function clean_line_for_yank(line)
  return (line:gsub("/%d+%s", ""):gsub("/%d+$", ""))
end

H.render_tree = function(instance, flat)
  -- Build parent_has_children_in_buffer cache
  local parent_has_children = {}
  local bufnr = instance.buf_id
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for l = 1, #lines do
    local p, _ = get_path_for_line(instance, l)
    if p then
      local parent = vim.fs.dirname(p)
      if parent then
        parent_has_children[parent] = true
      end
    end
  end
  instance._parent_has_children_in_buffer = parent_has_children

  local visible = {}
  local rows = {}
  local id_to_line = {}

  for _, item in ipairs(flat) do
    local is_deleted = false
    for del_path, _ in pairs(M.clipboard.deleted) do
      if item.path == del_path or item.path:sub(1, #del_path + 1) == del_path .. '/' then
        is_deleted = true
        break
      end
    end

    if not is_deleted and not libfs.is_hidden(item.path, instance.cache.ui.hidden_items) then
      local children, name_col = H.build_fs_entry_ui(instance, item)
      item._name_col = name_col
      visible[#visible + 1] = item
      id_to_line[item.id] = #visible + 1
      rows[#rows + 1] = { tag = 'row', children = children }
    end
  end

  -- Prepend parent folder header row
  local header_row = {
    tag = 'row',
    children = {
      { tag = 'text', value = '.. (' .. instance.state.pseudo_root_path:gsub("[/\\]+$", ""):gsub("/", "\\") .. '\\..)', hl = 'FylerDirectoryName' }
    }
  }
  table.insert(rows, 1, header_row)

  instance._id_to_line = id_to_line

  local component = { tag = 'col', children = rows }
  local buf_tick = vim.b[instance.buf_id].changedtick
  local Files
  if vim.b[instance.buf_id].fyler_prev_comp and buf_tick == (vim.b[instance.buf_id].fyler_prev_tick or -1) then
    Files = libui.compose(component, vim.b[instance.buf_id].fyler_prev_comp)
  else
    Files = libui.compose(component)
  end

  vim.b[instance.buf_id].fyler_prev_comp = component

  local hl_ns = vim.api.nvim_create_namespace('FylerFinderBuf' .. instance.buf_id)

  for _, change in ipairs(Files.changes) do
    vim.api.nvim_buf_set_lines(instance.buf_id, change.start_row, change.end_row, false, change.lines)
  end

  vim.b[instance.buf_id].fyler_prev_tick = vim.b[instance.buf_id].changedtick

  vim.api.nvim_buf_clear_namespace(instance.buf_id, hl_ns, 0, -1)

  for _, hl in ipairs(Files.highlights) do
    vim.api.nvim_buf_set_extmark(
      instance.buf_id,
      hl_ns,
      hl.start_row,
      hl.start_col,
      { hl_group = hl.hl_group, end_row = hl.end_row, end_col = hl.end_col, hl_mode = 'combine' }
    )
  end

  for _, em in ipairs(Files.extmarks) do
    pcall(vim.api.nvim_buf_set_extmark, instance.buf_id, hl_ns, em.row, em.col, em.opts)
  end

  vim.bo[instance.buf_id].modified = false
  vim.bo[instance.buf_id].syntax = 'fyler_finder'

  return visible, hl_ns, Files.lines
end

function Finder:close()
  self._view = vim.fn.winsaveview()

  if not util.window_is_valid(self.win_id) then return end

  pcall(vim.api.nvim_win_close, self.win_id, true)
  pcall(vim.api.nvim_win_call, self.win_id, function()
    if not util.window_is_valid(self.win_id) then return end
    pcall(vim.api.nvim_buf_delete, self.buf_id, { force = true })
  end)

  extensions.run_hook('finder_close_post', self)

  self.win_id = nil
  self._refresh_count = nil
  self._pending_refresh = nil

  if #vim.fn.win_findbuf(self.buf_id) == 0 then pcall(vim.api.nvim_buf_delete, self.buf_id, { force = true }) end

  vim.cmd.tcd({ args = { vim.fn.fnameescape(vim.fn.getcwd(-1, -1)) }, mods = { silent = true } })
end

---@param args { target_path: string|nil, force: boolean|nil }|nil
function Finder:follow(args)
  args = args or {}

  local raw_path = libpath.to_normalize(args.target_path)
  if not (raw_path and vim.uv.fs_stat(libpath.to_rel(self.state.pseudo_root_path, raw_path))) then
    if not self._refresh_count then self:refresh() end
    return
  end

  local target_path = libpath.to_abs(raw_path)
  local root_path = self.state.pseudo_root_path

  if target_path == root_path then
    if not self._refresh_count then self:refresh() end
    return
  end

  local expand_target = target_path
  if not self.state.scheme.fs_is_dir(target_path) then expand_target = vim.fs.dirname(target_path) end

  local relative = libpath.to_rel(root_path, expand_target)
  if not relative or #relative == 0 then
    if not self._refresh_count then self:refresh() end
    return
  end

  local accumulated = root_path
  for _, segment in ipairs(libpath.do_split(relative)) do
    accumulated = libpath.do_join(accumulated, segment)
    self.state:toggle(accumulated, true)
  end

  self:refresh({
    force = args.force,
    recursive = true,
    callback = function()
      if not util.window_is_valid(self.win_id) then return end
      local id = state.store_path_id[libpath.to_key(target_path)]
      if not id then return end
      self._view.lnum = self._id_to_line[id] or 1
    end,
  })
end

function Finder:mutate()
  if not vim.api.nvim_get_option_value('modified', { buf = self.buf_id }) then return end

  local id_to_path = {}
  self.state:walk(function(node, depth)
    if depth == 0 then return end
    id_to_path[node.value] = state.store[node.value].path
  end, { skip_hidden = true, sort_children = true, hidden_items = self.cache.ui.hidden_items })

  local buf_lines = vim
    .iter(vim.api.nvim_buf_get_lines(self.buf_id, 0, -1, false))
    :filter(function(buf_line) return #buf_line > 0 end)
    :totable()
  if #buf_lines > 0 then
    table.remove(buf_lines, 1)
  end

  local fs_actions, errors = H.compute_fs_actions(self, id_to_path, buf_lines)

  -- Identify which paths are being deleted in this batch
  local deleted_paths = {}
  for _, action in ipairs(fs_actions) do
    if action.name == "delete" and action.src then
      deleted_paths[action.src:gsub("[/\\]+$", "")] = true
    end
  end

  -- Filter out colliding create/move/copy actions where target already exists
  local filtered_fs_actions = {}
  for _, action in ipairs(fs_actions) do
    local skip = false
    if action.name ~= "delete" and action.dst then
      local clean_dst = action.dst:gsub("[/\\]+$", "")
      if vim.uv.fs_stat(libpath.to_os(clean_dst)) ~= nil and not deleted_paths[clean_dst] then
        skip = true
      end
    end
    if not skip then
      table.insert(filtered_fs_actions, action)
    end
  end
  fs_actions = filtered_fs_actions

  local graph, in_degree = H.build_action_dependency_graph(fs_actions, self.state.pseudo_root_path, errors)

  local queue = {}
  for i = 1, #fs_actions do
    if in_degree[i] == 0 then table.insert(queue, i) end
  end

  local order = {}
  while #queue > 0 do
    local u = table.remove(queue, 1)
    table.insert(order, u)
    for _, v in ipairs(graph[u] or {}) do
      in_degree[v] = in_degree[v] - 1
      if in_degree[v] == 0 then table.insert(queue, v) end
    end
  end

  if #order < #fs_actions then
    local cycled = {}
    for i = 1, #fs_actions do
      if in_degree[i] > 0 then table.insert(cycled, i) end
    end

    local resolved = false
    if #cycled == 2 then
      local a1, a2 = fs_actions[cycled[1]], fs_actions[cycled[2]]
      if a1.name == 'move' and a2.name == 'move' and a1.src == a2.dst and a1.dst == a2.src then
        resolved = true
        local tmp = a1.src .. '.fyler_tmp'
        table.insert(fs_actions, { name = 'move', src = a1.src, dst = tmp })
        table.insert(fs_actions, { name = 'move', src = a2.src, dst = a1.src })
        table.insert(fs_actions, { name = 'move', src = tmp, dst = a1.dst })
        vim.list_extend(order, { #fs_actions - 2, #fs_actions - 1, #fs_actions })
      end
    end

    if not resolved then
      for _, i in ipairs(cycled) do
        local action = fs_actions[i]
        table.insert(errors, ('Cycle detected: %s %s -> %s'):format(action.name, action.src or '', action.dst or ''))
      end
    end
  end

  if #errors > 0 then
    vim.notify(table.concat(errors, '\n'), vim.log.levels.ERROR)
    return
  end

  if #order == 0 then
    util.buffer_set_option(self.buf_id, 'modified', false)
    return
  end

  extensions.run_hook('finder_mutate_pre', fs_actions)

  local action_counts = { create = 0, delete = 0, move = 0, copy = 0, trash = 0 }
  for _, i in ipairs(order) do
    local a = fs_actions[i]
    action_counts[a.name] = action_counts[a.name] + 1
  end

  local is_simple = action_counts.copy <= 1
    and action_counts.delete <= 0
    and action_counts.trash <= 0
    and action_counts.move <= 1
    and action_counts.create <= 5

  local do_execute = function()
    local ordered_actions = vim.iter(order):map(function(i) return fs_actions[i] end):totable()
    local function execute()
      self.state.scheme.fs_mutate(ordered_actions, function(err)
        vim.schedule(function()
          if err then
            vim.notify('Failed to apply changes: ' .. err, vim.log.levels.ERROR)
            return
          end

          util.buffer_set_option(self.buf_id, 'modified', false)

          -- Update fyler_state paths for moved parent folders and their children
          for _, action in ipairs(ordered_actions) do
            if action.name == 'move' then
              local src = action.src
              local dst = action.dst
              local src_prefix = src:gsub("[/\\]+$", "") .. "/"
              local dst_prefix = dst:gsub("[/\\]+$", "") .. "/"
              
              for _, entry in pairs(state.store) do
                if entry.path then
                  local entry_path = entry.path:gsub("[/\\]+$", "")
                  if entry_path == src:gsub("[/\\]+$", "") then
                    entry.path = dst
                    entry.name = vim.fs.basename(dst)
                    local k_old = libpath.to_key(src)
                    local k_new = libpath.to_key(dst)
                    state.store_path_id[k_new] = state.store_path_id[k_old]
                    state.store_path_id[k_old] = nil

                    -- Update parent's children node reference in the state trie
                    local parent_path = vim.fs.dirname(src)
                    local rel = libpath.to_rel(self.state.pseudo_root_path, parent_path)
                    local parent_node = self.state.root
                    if rel and rel ~= "" then
                      local segments = libpath.do_split(rel)
                      for _, segment in ipairs(segments) do
                        if parent_node.children and parent_node.children[segment] then
                          parent_node = parent_node.children[segment]
                        else
                          parent_node = nil
                          break
                        end
                      end
                    end
                    local old_name = vim.fs.basename(src)
                    local new_name = vim.fs.basename(dst)
                    if parent_node and parent_node.children and parent_node.children[old_name] then
                      local child_node = parent_node.children[old_name]
                      parent_node.children[new_name] = child_node
                      parent_node.children[old_name] = nil
                    end
                  elseif entry.path:sub(1, #src_prefix) == src_prefix then
                    local rel = entry.path:sub(#src_prefix + 1)
                    local old_path = entry.path
                    entry.path = dst_prefix .. rel
                    
                    local k_old = libpath.to_key(old_path)
                    local k_new = libpath.to_key(entry.path)
                    state.store_path_id[k_new] = state.store_path_id[k_old]
                    state.store_path_id[k_old] = nil
                  end
                end
              end
            end
          end

          M.clipboard.deleted = {}
          M.clipboard.items = {}
          M.clipboard.action = nil

          local cursor_target = nil
          for i = #ordered_actions, 1, -1 do
            local action = ordered_actions[i]
            if not (action.name == 'delete' or action.name == 'trash') then
              cursor_target = action.dst
              break
            end
          end
          if cursor_target then
            self:follow({ target_path = cursor_target, force = true })
          else
            self:refresh({ force = true, recursive = true })
          end
          local hooks = config.DATA.hooks
          for _, action in ipairs(ordered_actions) do
            if action.name == 'delete' then
              vim.schedule_wrap(hooks.on_delete)(action.src)
            elseif action.name == 'move' then
              vim.schedule_wrap(hooks.on_rename)(action.src, action.dst)
            end
          end

          -- Close + jump if <C-s> triggered this write
          if _G.fyler_cs_save then
            _G.fyler_cs_save = nil
            local is_single_file_create = false
            local file_to_open = nil
            if #ordered_actions == 1 then
              local action = ordered_actions[1]
              if action.name == "create" and not action.dst:match("[/\\]$") then
                is_single_file_create = true
                file_to_open = action.dst
              end
            end

            vim.schedule(function()
              self:close()
              if is_single_file_create and file_to_open then
                vim.schedule(function()
                  local libpath = require("fyler.lib.path")
                  local os_path = libpath.to_os(libpath.to_abs(file_to_open))
                  vim.cmd('edit ' .. vim.fn.fnameescape(os_path))
                end)
              end
            end)
          end
        end)
      end)
    end

    extensions.run_hook(
      'finder_execute_pre',
      ordered_actions,
      util.promise_all(extensions.hook_count('finder_execute_pre'), execute)
    )
  end

  if config.DATA.auto_confirm_simple_mutation and is_simple then
    do_execute()
  else
    local lines, highlights = H.build_action_confirmation_ui(order, fs_actions, self.state.pseudo_root_path)
    vim.schedule_wrap(input.get_confirmation)(lines, highlights, function(confirmed)
      if confirmed then
        -- 'close' means <C-s> was pressed in the confirmation window
        if confirmed == 'close' then _G.fyler_cs_save = true end
        do_execute()
      end
    end)
  end
end


  local function set_fyler_hl()
    vim.api.nvim_set_hl(0, "FylerIndentScope", { fg = "#c678dd", bold = true, default = true })
    vim.api.nvim_set_hl(0, "SnacksIndent", { link = "FylerIndentGuide", default = true })
  end

  local function get_item_info_at_lnum(inst, lnum)
    local bufnr = inst.buf_id
    local path, is_dir = get_path_for_line(inst, lnum)
    if not path then return nil end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local target_depth = get_line_depth(bufnr, lnum)

    local item_lines = { { lnum = lnum, text = lines[lnum] } }
    for i = lnum + 1, #lines do
      local d = get_line_depth(bufnr, i)
      if d > target_depth then
        table.insert(item_lines, { lnum = i, text = lines[i] })
      else
        break
      end
    end

    return {
      path = path,
      is_dir = is_dir,
      lines = item_lines,
    }
  end

  local function toggle_clipboard(item_info, action)
    if M.clipboard.action ~= action then
      M.clipboard.action = action
      M.clipboard.items = { item_info }
    else
      local found_idx = nil
      for idx, item in ipairs(M.clipboard.items) do
        if item.path == item_info.path then
          found_idx = idx
          break
        end
      end

      if found_idx then
        table.remove(M.clipboard.items, found_idx)
        if #M.clipboard.items == 0 then
          M.clipboard.action = nil
        end
      else
        table.insert(M.clipboard.items, item_info)
      end
    end
  end

  local function get_unique_dst(src, dst_dir, current_paths)
    local name = vim.fs.basename(src)
    local dst = dst_dir .. "/" .. name
    local uv_or_loop = vim.uv or vim.loop
    
    if not uv_or_loop.fs_stat(dst) and not current_paths[dst] then
      return dst
    end

    local stem = name
    local ext = ""
    local stat = uv_or_loop.fs_stat(src)
    local is_dir = stat and stat.type == "directory"
    if not is_dir then
      local dot_idx = name:match("^%.") and name:sub(2):find(".", 1, true)
      if dot_idx then
        dot_idx = dot_idx + 1
        stem = name:sub(1, dot_idx - 1)
        ext = name:sub(dot_idx)
      elseif not name:match("^%.") then
        local last_dot = name:find("%.[^%.]*$")
        if last_dot then
          stem = name:sub(1, last_dot - 1)
          ext = name:sub(last_dot)
        end
      end
    end

    local counter = 1
    while true do
      local suffix = "_copy" .. (counter > 1 and tostring(counter) or "")
      local new_name = stem .. suffix .. ext
      local new_dst = dst_dir .. "/" .. new_name
      if not uv_or_loop.fs_stat(new_dst) and not current_paths[new_dst] then
        return new_dst
      end
      counter = counter + 1
    end
  end

  local function prompt_duplicate_resolver(inst, items_to_paste, target_dir, on_resolve)
    local buf = vim.api.nvim_create_buf(false, true)
    local buffer_lines = {}
    local pseudo_root = inst.state.pseudo_root_path
    
    for _, item in ipairs(items_to_paste) do
      local rel_src = item.src
      local rel_suggested = item.suggested
      
      if item.src:sub(1, #pseudo_root) == pseudo_root then
        rel_src = item.src:sub(#pseudo_root + 2)
        if rel_src == "" then rel_src = item.src end
      end
      if item.suggested:sub(1, #pseudo_root) == pseudo_root then
        rel_suggested = item.suggested:sub(#pseudo_root + 2)
        if rel_suggested == "" then rel_suggested = item.suggested end
      end
      
      table.insert(buffer_lines, "duplicate " .. rel_src .. " -> " .. rel_suggested)
    end
    
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buffer_lines)
    
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.min(#buffer_lines + 2, 15)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      border = "rounded",
      title = " Resolve Duplicate Names (Ctrl-s to apply) ",
      title_pos = "center",
    })
    
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "fyler_duplicate_resolver"
    
    vim.keymap.set("n", "<C-s>", function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local resolved_items = {}
      for idx, line in ipairs(lines) do
        local rel_src, rel_dst = line:match("^duplicate%s+(.-)%s*->%s*(.-)%s*$")
        if not rel_src or not rel_dst then
          vim.notify("Invalid line format: " .. line, vim.log.levels.ERROR)
          return
        end
        
        local dst_path = rel_dst
        if not (rel_dst:sub(1, 1) == "/" or rel_dst:match("^%a:")) then
          dst_path = pseudo_root .. "/" .. rel_dst
        end
        
        local orig_item = items_to_paste[idx]
        table.insert(resolved_items, {
          src = orig_item.src,
          dst = dst_path,
          is_dir = orig_item.is_dir,
          item = orig_item.item,
          is_internal = orig_item.is_internal,
          is_system = orig_item.is_system,
          name = orig_item.name,
        })
      end
      
      pcall(vim.api.nvim_win_close, win, true)
      on_resolve(resolved_items)
    end, { buffer = buf, silent = true, nowait = true })

    vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, silent = true, nowait = true })
    vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, silent = true, nowait = true })
  end

  local function apply_fyler_highlights(inst)
    local bufnr = inst.buf_id
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    if vim.bo[bufnr].filetype ~= "fyler_finder" then return end

    local hl_ns = vim.api.nvim_create_namespace("fyler_folder_colors")
    vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)

    vim.api.nvim_set_hl(0, "FylerDeletedVT", { fg = "#e06c75", bold = true, italic = true, default = true })
    vim.api.nvim_set_hl(0, "FylerCopiedVT", { fg = "#98c379", italic = true, default = true })
    vim.api.nvim_set_hl(0, "FylerMovedVT", { fg = "#e5c07b", italic = true, default = true })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    
    local id_counts = {}
    for _, line in ipairs(lines) do
      local id = line:match("/(%d+)")
      if id then
        local id_num = tonumber(id)
        id_counts[id_num] = (id_counts[id_num] or 0) + 1
      end
    end

    for id_num, _ in pairs(id_counts) do
      local entry = state.store[id_num]
      if entry and entry.path then
        M.clipboard.deleted[entry.path] = nil
      end
    end

    -- Identify implicit moves due to parent renames
    local function is_implicit_move(path, entry_path)
      if path == entry_path then return false end
      local cur = path
      local orig = entry_path
      while true do
        local parent_cur = vim.fs.dirname(cur)
        local parent_orig = vim.fs.dirname(orig)
        if not parent_cur or not parent_orig or parent_cur == cur or parent_orig == orig then
          break
        end
        -- check if parent was moved
        local p_id = state.store_path_id[libpath.to_key(parent_orig)]
        if p_id then
          local p_entry = state.store[p_id]
          if p_entry and p_entry.path then
            -- Find the current path of this parent in the buffer
            local p_current_path = nil
            for l = 1, #lines do
              local line = lines[l]
              if line:match("/" .. p_id .. "%s") or line:match("/" .. p_id .. "$") then
                p_current_path = get_path_for_line(inst, l)
                break
              end
            end
            if p_current_path and p_current_path ~= p_entry.path then
              local suffix = orig:sub(#parent_orig + 1)
              if parent_cur .. suffix == cur and p_current_path .. suffix == cur then
                return true
              end
            end
          end
        end
        cur = parent_cur
        orig = parent_orig
      end
      return false
    end

    for i, line in ipairs(lines) do
      local current_path, is_dir = get_path_for_line(inst, i)
      if current_path then
        if i == 1 then
          -- Special handling for the parent folder header
          local deleted_count = 0
          for del_path, _ in pairs(M.clipboard.deleted) do
            local parent_path = vim.fs.dirname(del_path)
            if parent_path == current_path then
              deleted_count = deleted_count + 1
            end
          end

          if deleted_count > 0 then
            table.insert(vt_chunks, { " (deleted: " .. deleted_count .. ")", "FylerDeletedVT" })
          end
        else
          -- Normal line highlighting and collision detection
          if is_dir then
            local count = get_line_depth(bufnr, i)
            local start_col = count * 4
            local is_empty = true
            if inst._parent_has_children_in_buffer and inst._parent_has_children_in_buffer[current_path] then
              is_empty = false
            else
              local uv = vim.uv or vim.loop
              local scan_path = current_path
              local id = line:match("/(%d+)")
              if id then
                local entry = state.store[tonumber(id)]
                if entry and entry.path and entry.type == "directory" then
                  if not uv.fs_stat(scan_path) then
                    scan_path = entry.path
                  end
                end
              end

              local handle = uv.fs_scandir(scan_path)
              if handle then
                while true do
                  local name, _ = uv.fs_scandir_next(handle)
                  if not name then break end
                  local child_path = scan_path .. "/" .. name
                  local check_path = child_path
                  if scan_path ~= current_path then
                    check_path = current_path .. "/" .. name
                  end
                  if not M.clipboard.deleted[check_path] then
                    is_empty = false
                    break
                  end
                end
              end
            end

            local key_path = current_path
            local id = line:match("/(%d+)")
            if id then
              local entry = state.store[tonumber(id)]
              if entry and entry.path and entry.type == "directory" then
                key_path = entry.path
              end
            end
            local is_expanded = inst.state.meta[libpath.to_key(key_path)] == true

            local new_icon, _ = icon.get(is_dir and "directory" or "file", key_path, { expanded = is_expanded })
            if not new_icon or new_icon == "" then
              if is_empty then
                new_icon = is_expanded and "" or ""
              else
                new_icon = is_expanded and "" or ""
              end
            end

            local after_guides = line:sub(count * 4 + 1)
            local icon_char, rest = after_guides:match("^(%S+)%s+(.*)$")
            if icon_char and icon_char:sub(1, 1) == "/" then
              rest = after_guides
              icon_char = ""
            end

            if icon_char and icon_char ~= new_icon then
              local new_line = line:sub(1, count * 4) .. new_icon .. " " .. rest
              if new_line ~= line then
                vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new_line })
                line = new_line
              end
            end

            pcall(vim.api.nvim_buf_set_extmark, bufnr, hl_ns, i - 1, start_col, {
              end_row = i - 1,
              end_col = #line,
              hl_group = "FylerDirectoryName",
              priority = 100,
              hl_mode = "combine",
            })

            local deleted_count = 0
            for del_path, _ in pairs(M.clipboard.deleted) do
              local parent_path = vim.fs.dirname(del_path)
              if parent_path == current_path then
                deleted_count = deleted_count + 1
              end
            end

            if deleted_count > 0 then
              table.insert(vt_chunks, { " (deleted: " .. deleted_count .. ")", "FylerDeletedVT" })
            end
          end

          local is_collision = false
          local clean_path = current_path:gsub("[/\\]+$", "")
          local exists = vim.uv.fs_stat(libpath.to_os(clean_path)) ~= nil
          local is_deleted_in_buffer = false
          for del_p, _ in pairs(M.clipboard.deleted) do
            if del_p:gsub("[/\\]+$", "") == clean_path then
              is_deleted_in_buffer = true
              break
            end
          end

          local id = line:match("/(%d+)")
          local id_num = id and tonumber(id) or nil
          if exists and not is_deleted_in_buffer then
            if not id then
              is_collision = true
            else
              local entry = state.store[id_num]
              if entry and entry.path and current_path ~= entry.path then
                is_collision = true
              end
            end
          end

          if is_collision then
            table.insert(vt_chunks, { " (already exists)", "FylerMovedVT" })
          elseif id_num then
            local entry = state.store[id_num]
            if entry and entry.path and current_path ~= entry.path then
              local rel_orig = entry.path
              local pseudo_root = inst.state.pseudo_root_path
              if entry.path:sub(1, #pseudo_root) == pseudo_root then
                rel_orig = entry.path:sub(#pseudo_root + 2)
                if rel_orig == "" then rel_orig = entry.path end
              end

              if not is_implicit_move(current_path, entry.path) then
                if id_counts[id_num] > 1 then
                  local current_name = vim.fs.basename(current_path)
                  local original_name = vim.fs.basename(entry.path)
                  if current_name ~= original_name then
                    table.insert(vt_chunks, { " (copied and renamed from " .. rel_orig .. ")", "FylerCopiedVT" })
                  else
                    table.insert(vt_chunks, { " (copied from " .. rel_orig .. ")", "FylerCopiedVT" })
                  end
                else
                  local current_dir = vim.fs.dirname(current_path)
                  local original_dir = vim.fs.dirname(entry.path)
                  if current_dir == original_dir then
                    local original_name = vim.fs.basename(entry.path)
                    table.insert(vt_chunks, { " (renamed from " .. original_name .. ")", "FylerMovedVT" })
                  else
                    table.insert(vt_chunks, { " (moved from " .. rel_orig .. ")", "FylerMovedVT" })
                  end
                end
              end
            end
          end
        end

        if #vt_chunks > 0 then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, hl_ns, i - 1, #line, {
            virt_text = vt_chunks,
            virt_text_pos = "eol",
          })
        end
      end
    end
  end

  local function update_fyler_clipboard_highlights(inst)
    local bufnr = inst.buf_id
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    if vim.bo[bufnr].filetype ~= "fyler_finder" then return end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = 1, #lines do
      local path, _ = get_path_for_line(inst, i)
      if path then
        M.clipboard.deleted[path] = nil
      end
    end

    local clipboard_ns = vim.api.nvim_create_namespace("fyler_clipboard_items")
    vim.api.nvim_buf_clear_namespace(bufnr, clipboard_ns, 0, -1)

    if not M.clipboard.items or #M.clipboard.items == 0 then
      return
    end

    local clipboard_map = {}
    for _, item in ipairs(M.clipboard.items) do
      clipboard_map[item.path] = true
    end

    vim.api.nvim_set_hl(0, "FylerCopied", { undercurl = true, sp = "#98c379", default = true })
    vim.api.nvim_set_hl(0, "FylerCut", { fg = "#e06c75", strikethrough = true, default = true })

    local hl_group = M.clipboard.action == "copy" and "FylerCopied" or "FylerCut"

    for i = 1, #lines do
      local path, _ = get_path_for_line(inst, i)
      if path and clipboard_map[path] then
        local count = get_line_depth(bufnr, i)
        local indent_len = count * 4

        local line = lines[i] or ""
        if #line > indent_len then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, clipboard_ns, i - 1, indent_len, {
            end_row = i - 1,
            end_col = #line,
            hl_group = hl_group,
            priority = 10000,
            hl_mode = "combine",
          })
        end
      end
    end
  end

  local function update_fyler_indent_scope(inst)
    local bufnr = inst.buf_id
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    if vim.bo[bufnr].filetype ~= "fyler_finder" then return end
    set_fyler_hl()

    local scope_ns = vim.api.nvim_create_namespace("fyler_indent_scope")
    vim.api.nvim_buf_clear_namespace(bufnr, scope_ns, 0, -1)

    local win_id = inst.win_id
    if not win_id or not vim.api.nvim_win_is_valid(win_id) then return end
    local cursor = vim.api.nvim_win_get_cursor(win_id)
    local lnum = cursor[1]
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    local count = get_line_depth(bufnr, lnum)
    if count == 0 then return end

    local start_lnum = lnum
    for l = lnum - 1, 1, -1 do
      if get_line_depth(bufnr, l) < count then
        start_lnum = l
        break
      end
    end

    local end_lnum = lnum
    for l = lnum + 1, line_count do
      if get_line_depth(bufnr, l) >= count then
        end_lnum = l
      else
        break
      end
    end

    local start_col = (count - 1) * 4
    local end_col = start_col + 3
    local hl = "FylerIndentScope"

    for l = start_lnum + 1, end_lnum do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, scope_ns, l - 1, start_col, {
        end_row = l - 1,
        end_col = end_col,
        hl_group = hl,
        priority = 9999,
        hl_mode = "replace",
      })
    end
  end

  local function update_fyler_unsaved_lines(inst)
    local bufnr = inst.buf_id
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    if vim.bo[bufnr].filetype ~= "fyler_finder" then return end

    local unsaved_ns = vim.api.nvim_create_namespace("fyler_unsaved_changes")
    vim.api.nvim_buf_clear_namespace(bufnr, unsaved_ns, 0, -1)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:match("%S") then
        local has_id = line:match('/%d+') ~= nil
        if not has_id then
          local count = get_line_depth(bufnr, i)
          local indent_len = count * 4

          if indent_len > 0 then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, unsaved_ns, i - 1, 0, {
              end_row = i - 1,
              end_col = indent_len,
              hl_group = "SnacksIndent",
              priority = 1000,
            })
          end

          vim.api.nvim_set_hl(0, "FylerUnsaved", { fg = "#98c379", bold = true, default = true })

          if #line > indent_len then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, unsaved_ns, i - 1, indent_len, {
              end_row = i - 1,
              end_col = #line,
              hl_group = "FylerUnsaved",
              priority = 1000,
            })
          end
        end
      end
    end
  end

  local function setup_buffer_mappings(self)
    local bufnr = self.buf_id

    vim.keymap.set("n", "<C-z>", "u", { buffer = bufnr, silent = true, nowait = true })

    vim.keymap.set("n", "<Esc>", function()
      M.clipboard.items = {}
      M.clipboard.action = nil
      update_fyler_clipboard_highlights(self)
    end, { buffer = bufnr, silent = true, nowait = true })

    vim.keymap.set("n", "<C-s>", function()
      _G.fyler_cs_save = true
      vim.cmd("write")
    end, { buffer = bufnr, silent = true, nowait = true })

    -- Copy in normal mode
    vim.keymap.set("n", "c", function()
      local lnum = vim.api.nvim_win_get_cursor(self.win_id)[1]
      if lnum == 1 then return end
      local item_info = get_item_info_at_lnum(self, lnum)
      if item_info then
        toggle_clipboard(item_info, "copy")
        update_fyler_clipboard_highlights(self)
        local yank_lines = {}
        for _, line_info in ipairs(item_info.lines) do
          table.insert(yank_lines, clean_line_for_yank(line_info.text))
        end
        if #yank_lines > 0 then
          local yank_text = table.concat(yank_lines, "\n")
          vim.fn.setreg("+", yank_text)
          vim.fn.setreg('"', yank_text)
        end
      end
    end, { buffer = bufnr, silent = true, nowait = true })

    -- Cut in normal mode
    vim.keymap.set("n", "x", function()
      local lnum = vim.api.nvim_win_get_cursor(self.win_id)[1]
      if lnum == 1 then return end
      local item_info = get_item_info_at_lnum(self, lnum)
      if item_info then
        toggle_clipboard(item_info, "move")
        update_fyler_clipboard_highlights(self)
      end
    end, { buffer = bufnr, silent = true, nowait = true })

    -- Copy in visual mode
    vim.keymap.set("v", "c", function()
      local start_line = vim.fn.line("v")
      local end_line = vim.fn.line(".")
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end
      if start_line == 1 then start_line = 2 end
      if start_line > end_line then return end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

      local top_level_lnums = {}
      local last_included_depth = -1
      local last_included_lnum = -1
      for l = start_line, end_line do
        local line_depth = get_line_depth(bufnr, l)
        if last_included_lnum == -1 then
          table.insert(top_level_lnums, l)
          last_included_lnum = l
          last_included_depth = line_depth
        else
          local is_child = false
          if l > last_included_lnum then
            local all_greater = true
            for check_l = last_included_lnum + 1, l do
              local cd = get_line_depth(bufnr, check_l)
              if cd <= last_included_depth then
                all_greater = false
                break
              end
            end
            if all_greater then
              is_child = true
            end
          end
          if not is_child then
            table.insert(top_level_lnums, l)
            last_included_lnum = l
            last_included_depth = line_depth
          end
        end
      end

      for _, l in ipairs(top_level_lnums) do
        local item_info = get_item_info_at_lnum(self, l)
        if item_info then
          toggle_clipboard(item_info, "copy")
        end
      end
      update_fyler_clipboard_highlights(self)
      local selected_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
      local yank_lines = {}
      for _, line in ipairs(selected_lines) do
        table.insert(yank_lines, clean_line_for_yank(line))
      end
      if #yank_lines > 0 then
        local yank_text = table.concat(yank_lines, "\n")
        vim.fn.setreg("+", yank_text)
        vim.fn.setreg('"', yank_text)
      end
    end, { buffer = bufnr, silent = true, nowait = true })

    -- Cut in visual mode
    vim.keymap.set("v", "x", function()
      local start_line = vim.fn.line("v")
      local end_line = vim.fn.line(".")
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end
      if start_line == 1 then start_line = 2 end
      if start_line > end_line then return end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

      local top_level_lnums = {}
      local last_included_depth = -1
      local last_included_lnum = -1
      for l = start_line, end_line do
        local line_depth = get_line_depth(bufnr, l)
        if last_included_lnum == -1 then
          table.insert(top_level_lnums, l)
          last_included_lnum = l
          last_included_depth = line_depth
        else
          local is_child = false
          if l > last_included_lnum then
            local all_greater = true
            for check_l = last_included_lnum + 1, l do
              local cd = get_line_depth(bufnr, check_l)
              if cd <= last_included_depth then
                all_greater = false
                break
              end
            end
            if all_greater then
              is_child = true
            end
          end
          if not is_child then
            table.insert(top_level_lnums, l)
            last_included_lnum = l
            last_included_depth = line_depth
          end
        end
      end

      for _, l in ipairs(top_level_lnums) do
        local item_info = get_item_info_at_lnum(self, l)
        if item_info then
          toggle_clipboard(item_info, "move")
        end
      end
      update_fyler_clipboard_highlights(self)
    end, { buffer = bufnr, silent = true, nowait = true })

    -- Paste in normal mode
    vim.keymap.set("n", "p", function()
      local target_lnum = vim.api.nvim_win_get_cursor(self.win_id)[1]
      local item_path, is_target_dir = get_path_for_line(self, target_lnum)
      local target_dir
      local target_depth
      local insert_after_lnum

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if #lines == 0 then
        target_depth = 0
        insert_after_lnum = 0
        target_dir = self.state.pseudo_root_path
      else
        local line_depth = get_line_depth(bufnr, target_lnum)
        if is_target_dir then
          target_depth = line_depth + 1
          target_dir = item_path
          insert_after_lnum = target_lnum
          for i = target_lnum + 1, #lines do
            local d = get_line_depth(bufnr, i)
            if d >= target_depth then
              insert_after_lnum = i
            else
              break
            end
          end
        else
          target_depth = line_depth
          target_dir = vim.fs.dirname(item_path)
          insert_after_lnum = target_lnum
        end
      end

      local current_paths = {}
      for i = 1, #lines do
        local p, _ = get_path_for_line(self, i)
        if p then current_paths[p] = true end
      end

      local is_internal = M.clipboard.items and #M.clipboard.items > 0
      local system_lines = {}
      if not is_internal then
        local reg_content = vim.fn.getreg("+")
        if reg_content == "" then reg_content = vim.fn.getreg('"') end
        if reg_content ~= "" then
          for s in reg_content:gmatch("[^\r\n]+") do
            local clean = s:gsub("^%s+", ""):gsub("%s+$", "")
            if clean ~= "" then table.insert(system_lines, clean) end
          end
        end
      end

      if not is_internal and #system_lines == 0 then return end

      local items_to_paste = {}
      local has_collision = false
      
      if is_internal then
        for _, item in ipairs(M.clipboard.items) do
          local name = vim.fs.basename(item.path)
          local default_dst = target_dir .. "/" .. name
          local collides = vim.uv.fs_stat(default_dst) ~= nil or current_paths[default_dst]
          if collides then has_collision = true end
          
          local suggested_dst = get_unique_dst(item.path, target_dir, current_paths)
          current_paths[suggested_dst] = true
          
          table.insert(items_to_paste, {
            src = item.path,
            suggested = suggested_dst,
            is_dir = item.is_dir,
            item = item,
            is_internal = true,
          })
        end
      else
        for _, clean in ipairs(system_lines) do
          local clean_name = clean
          if clean_name:sub(-1) == "/" or clean_name:sub(-1) == "\\" then
            clean_name = clean_name:sub(1, -2)
          end
          local default_dst = target_dir .. "/" .. clean_name
          local collides = vim.uv.fs_stat(default_dst) ~= nil or current_paths[default_dst]
          if collides then has_collision = true end
          
          local suggested_dst = get_unique_dst(default_dst, target_dir, current_paths)
          current_paths[suggested_dst] = true
          
          table.insert(items_to_paste, {
            src = default_dst,
            suggested = suggested_dst,
            is_dir = clean:match("[/\\]%s*$") ~= nil,
            name = clean,
            is_system = true,
          })
        end
      end

      local function do_paste(resolved_items)
        local actual_current_paths = {}
        for i = 1, #lines do
          local p, _ = get_path_for_line(self, i)
          if p then actual_current_paths[p] = true end
        end

        if is_internal then
          local delete_set = {}
          if M.clipboard.action == "move" then
            for _, item in ipairs(M.clipboard.items) do
              for _, line_info in ipairs(item.lines) do
                delete_set[line_info.lnum] = true
              end
            end
          end

          local new_lines = {}
          for _, resolved in ipairs(resolved_items) do
            local item = resolved.item
            local orig_top_line = item.lines[1].text
            local orig_top_depth = get_line_depth(bufnr, item.lines[1].lnum)

            local id_prefix, orig_name = orig_top_line:match("/(%d+)%s+(.-)$")
            if not id_prefix then
              orig_name = orig_top_line:sub(orig_top_depth * 4 + 1):gsub("^%s+", ""):gsub("%s+$", "")
            end
            
            local is_item_dir = orig_name:match("[/\\]%s*$") ~= nil or (id_prefix and item.is_dir)
            
            local unique_dst = resolved.dst
            actual_current_paths[unique_dst] = true
            M.clipboard.deleted[unique_dst] = nil
            
            local dst_name = vim.fs.basename(unique_dst)
            if is_item_dir then dst_name = dst_name .. "/" end

            for _, line_info in ipairs(item.lines) do
              local d = get_line_depth(bufnr, line_info.lnum)
              local depth_diff = d - orig_top_depth
              local new_depth = target_depth + depth_diff
              local prefix = string.rep("│ ", new_depth)

              local line_id = line_info.text:match("/(%d+)")
              local line_name
              if line_info.lnum == item.lines[1].lnum then
                line_name = dst_name
              else
                local child_id, child_name = line_info.text:match("/(%d+)%s+(.-)$")
                if child_id then
                  line_name = child_name
                else
                  local child_depth = get_line_depth(bufnr, line_info.lnum)
                  line_name = line_info.text:sub(child_depth * 4 + 1):gsub("^%s+", ""):gsub("%s+$", "")
                end
              end

              local formatted_line
              if line_id then
                formatted_line = prefix .. "/" .. line_id .. " " .. line_name
              else
                formatted_line = prefix .. line_name
              end
              table.insert(new_lines, formatted_line)
            end
          end

          local final_lines = {}
          if insert_after_lnum == 0 then
            for _, nl in ipairs(new_lines) do table.insert(final_lines, nl) end
          end

          for i = 1, #lines do
            local is_deleted = delete_set[i]
            if not is_deleted then table.insert(final_lines, lines[i]) end
            if i == insert_after_lnum then
              for _, nl in ipairs(new_lines) do table.insert(final_lines, nl) end
            end
          end

          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final_lines)

          M.clipboard.items = {}
          M.clipboard.action = nil
          update_fyler_clipboard_highlights(self)

          local new_cursor_lnum = insert_after_lnum + 1
          local deleted_before_insert = 0
          for lnum_del, _ in pairs(delete_set) do
            if lnum_del <= insert_after_lnum then
              deleted_before_insert = deleted_before_insert + 1
            end
          end
          new_cursor_lnum = math.max(1, new_cursor_lnum - deleted_before_insert)
          pcall(vim.api.nvim_win_set_cursor, self.win_id, { new_cursor_lnum, 0 })
        else
          local new_lines = {}
          for _, resolved in ipairs(resolved_items) do
            local prefix = string.rep("│ ", target_depth)
            local clean = resolved.name
            local clean_name = clean
            if clean_name:sub(-1) == "/" or clean_name:sub(-1) == "\\" then
              clean_name = clean_name:sub(1, -2)
            end
            
            local dst_name = vim.fs.basename(resolved.dst)
            if resolved.is_dir then dst_name = dst_name .. "/" end
            table.insert(new_lines, prefix .. dst_name)
          end

          local final_lines = {}
          if insert_after_lnum == 0 then
            for _, nl in ipairs(new_lines) do table.insert(final_lines, nl) end
          end

          for i = 1, #lines do
            table.insert(final_lines, lines[i])
            if i == insert_after_lnum then
              for _, nl in ipairs(new_lines) do table.insert(final_lines, nl) end
            end
          end

          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final_lines)

          local new_cursor_lnum = insert_after_lnum + 1
          pcall(vim.api.nvim_win_set_cursor, self.win_id, { new_cursor_lnum, 0 })
        end
      end

      if has_collision then
        prompt_duplicate_resolver(self, items_to_paste, target_dir, do_paste)
      else
        local resolved_items = {}
        for _, item in ipairs(items_to_paste) do
          table.insert(resolved_items, {
            src = item.src,
            dst = item.suggested,
            is_dir = item.is_dir,
            item = item.item,
            is_internal = item.is_internal,
            is_system = item.is_system,
            name = item.name,
          })
        end
        do_paste(resolved_items)
      end
    end, { buffer = bufnr, silent = true, nowait = true })

    -- Delete in normal mode
    vim.keymap.set("n", "dd", function()
      local lnum = vim.api.nvim_win_get_cursor(self.win_id)[1]
      if lnum == 1 then return end
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if #lines == 0 then return end

      local target_depth = get_line_depth(bufnr, lnum)
      local delete_set = { [lnum] = true }
      for i = lnum + 1, #lines do
        local d = get_line_depth(bufnr, i)
        if d > target_depth then
          delete_set[i] = true
        else
          break
        end
      end

      for l_del, _ in pairs(delete_set) do
        local p, _ = get_path_for_line(self, l_del)
        local del_line = lines[l_del] or ""
        local id = del_line:match("/(%d+)")
        local is_persisted = false
        if id and p then
          local id_num = tonumber(id)
          local entry = state.store[id_num]
          if entry and entry.path then
            if p == entry.path then
              is_persisted = true
            else
              local occurrences = 0
              for _, line in ipairs(lines) do
                if line:match("/" .. id_num .. "%s") or line:match("/" .. id_num .. "$") then
                  occurrences = occurrences + 1
                end
              end
              if occurrences == 1 then is_persisted = true end
            end
          end
        end
        if is_persisted then M.clipboard.deleted[p] = true end
      end

      local to_delete = {}
      for lnum_del, _ in pairs(delete_set) do
        table.insert(to_delete, lnum_del)
      end
      table.sort(to_delete, function(a, b) return a > b end)

      for _, lnum_del in ipairs(to_delete) do
        vim.api.nvim_buf_set_lines(bufnr, lnum_del - 1, lnum_del, false, {})
      end

      local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local new_lnum = math.min(lnum, #final_lines)
      if new_lnum > 0 then pcall(vim.api.nvim_win_set_cursor, self.win_id, { new_lnum, 0 }) end
      update_fyler_clipboard_highlights(self)
    end, { buffer = bufnr, silent = true, nowait = true })

    -- Delete in visual mode
    vim.keymap.set("v", "d", function()
      local start_line = vim.fn.line("v")
      local end_line = vim.fn.line(".")
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end
      if start_line == 1 then start_line = 2 end
      if start_line > end_line then return end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if #lines == 0 then return end

      local delete_set = {}
      for l = start_line, end_line do
        delete_set[l] = true
        local depth = get_line_depth(bufnr, l)
        for i = l + 1, #lines do
          local d = get_line_depth(bufnr, i)
          if d > depth then
            delete_set[i] = true
          else
            break
          end
        end
      end

      for l_del, _ in pairs(delete_set) do
        local p, _ = get_path_for_line(self, l_del)
        local del_line = lines[l_del] or ""
        local id = del_line:match("/(%d+)")
        local is_persisted = false
        if id and p then
          local id_num = tonumber(id)
          local entry = state.store[id_num]
          if entry and entry.path then
            if p == entry.path then
              is_persisted = true
            else
              local occurrences = 0
              for _, line in ipairs(lines) do
                if line:match("/" .. id_num .. "%s") or line:match("/" .. id_num .. "$") then
                  occurrences = occurrences + 1
                end
              end
              if occurrences == 1 then is_persisted = true end
            end
          end
        end
        if is_persisted then M.clipboard.deleted[p] = true end
      end

      local to_delete = {}
      for lnum_del, _ in pairs(delete_set) do
        table.insert(to_delete, lnum_del)
      end
      table.sort(to_delete, function(a, b) return a > b end)

      for _, lnum_del in ipairs(to_delete) do
        vim.api.nvim_buf_set_lines(bufnr, lnum_del - 1, lnum_del, false, {})
      end

      local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local new_lnum = math.min(start_line, #final_lines)
      if new_lnum > 0 then pcall(vim.api.nvim_win_set_cursor, self.win_id, { new_lnum, 0 }) end
      update_fyler_clipboard_highlights(self)
    end, { buffer = bufnr, silent = true, nowait = true })

    -- 'o' in normal mode
    vim.keymap.set("n", "o", function()
      local lnum = vim.api.nvim_win_get_cursor(self.win_id)[1]
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      local count = 0
      for _ in line:gmatch("│ ") do count = count + 1 end
      local indent = string.rep("│ ", count)
      vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { indent })
      vim.api.nvim_win_set_cursor(self.win_id, { lnum + 1, #indent })
      vim.cmd("startinsert!")
    end, { buffer = bufnr, silent = true })

    -- 'O' in normal mode
    vim.keymap.set("n", "O", function()
      local lnum = vim.api.nvim_win_get_cursor(self.win_id)[1]
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      local count = 0
      for _ in line:gmatch("│ ") do count = count + 1 end
      local indent = string.rep("│ ", count)
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum - 1, false, { indent })
      vim.api.nvim_win_set_cursor(self.win_id, { lnum, #indent })
      vim.cmd("startinsert!")
    end, { buffer = bufnr, silent = true })

    -- Replace current line ('rr')
    local function replace_current_line()
      local lnum = vim.api.nvim_win_get_cursor(self.win_id)[1]
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      local id = line:match("/(%d+)")
      local prefix
      if id then
        prefix = line:match("^([%s%S]*/" .. id .. "%s+)")
      else
        prefix = line:match("^([│ \t]*%S+%s+)")
      end
      if not prefix then
        local count = 0
        for _ in line:gmatch("│ ") do count = count + 1 end
        prefix = string.rep("│ ", count)
      end
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { prefix })
      vim.api.nvim_win_set_cursor(self.win_id, { lnum, #prefix })
      vim.cmd("startinsert!")
    end
    vim.keymap.set("n", "rr", replace_current_line, { buffer = bufnr, silent = true })

    -- '<BS>' in insert mode
    vim.keymap.set("i", "<BS>", function()
      local cursor = vim.api.nvim_win_get_cursor(self.win_id)
      local lnum = cursor[1]
      local col = cursor[2]
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""

      local min_col
      local id = line:match("/(%d+)")
      if id then
        local prefix = line:match("^[%s%S]*/" .. id .. "%s+")
        min_col = prefix and #prefix or 0
      else
        local prefix = line:match("^([│ \t]*%S+%s+)")
        min_col = prefix and #prefix or 0
      end

      if col <= min_col then return end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "n", false)
    end, { buffer = bufnr, silent = true })

    -- '<CR>' in insert mode
    vim.keymap.set("i", "<CR>", function()
      local cursor = vim.api.nvim_win_get_cursor(self.win_id)
      local lnum = cursor[1]
      local col = cursor[2]
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""

      local count = 0
      for _ in line:gmatch("│ ") do count = count + 1 end
      local indent = string.rep("│ ", count)

      local before = line:sub(1, col)
      local after = line:sub(col + 1)

      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { before })
      vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { indent .. after })
      vim.api.nvim_win_set_cursor(self.win_id, { lnum + 1, #indent })
    end, { buffer = bufnr, silent = true })

    -- Indent (Tab) in normal mode
    vim.keymap.set("n", "<Tab>", function()
      local lnum = vim.api.nvim_win_get_cursor(self.win_id)[1]
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { "│ " .. line })
      local cursor = vim.api.nvim_win_get_cursor(self.win_id)
      vim.api.nvim_win_set_cursor(self.win_id, { cursor[1], cursor[2] + 4 })
    end, { buffer = bufnr, silent = true })

    -- Deindent (S-Tab) in normal mode
    vim.keymap.set("n", "<S-Tab>", function()
      local lnum = vim.api.nvim_win_get_cursor(self.win_id)[1]
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      if line:sub(1, 4) == "│ " then
        vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line:sub(5) })
        local cursor = vim.api.nvim_win_get_cursor(self.win_id)
        vim.api.nvim_win_set_cursor(self.win_id, { cursor[1], math.max(0, cursor[2] - 4) })
      end
    end, { buffer = bufnr, silent = true })

    -- Indent (Tab) in insert mode
    vim.keymap.set("i", "<Tab>", function()
      local cursor = vim.api.nvim_win_get_cursor(self.win_id)
      local lnum = cursor[1]
      local col = cursor[2]
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { "│ " .. line })
      vim.api.nvim_win_set_cursor(self.win_id, { lnum, col + 4 })
    end, { buffer = bufnr, silent = true })

    -- Deindent (S-Tab) in insert mode
    vim.keymap.set("i", "<S-Tab>", function()
      local cursor = vim.api.nvim_win_get_cursor(self.win_id)
      local lnum = cursor[1]
      local col = cursor[2]
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      if line:sub(1, 4) == "│ " then
        vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line:sub(5) })
        vim.api.nvim_win_set_cursor(self.win_id, { lnum, math.max(0, col - 4) })
      end
    end, { buffer = bufnr, silent = true })

    -- Sibling navigation 'gj' and 'gk'
    vim.keymap.set("n", "gj", function()
      local cursor = vim.api.nvim_win_get_cursor(self.win_id)
      local lnum = cursor[1]
      local col = cursor[2]
      local line_count = vim.api.nvim_buf_line_count(bufnr)

      local target_depth = get_line_depth(bufnr, lnum)
      for l = lnum + 1, line_count do
        local d = get_line_depth(bufnr, l)
        if d == target_depth then
          vim.api.nvim_win_set_cursor(self.win_id, { l, col })
          break
        elseif d < target_depth then
          break
        end
      end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "gk", function()
      local cursor = vim.api.nvim_win_get_cursor(self.win_id)
      local lnum = cursor[1]
      local col = cursor[2]

      local target_depth = get_line_depth(bufnr, lnum)
      for l = lnum - 1, 1, -1 do
        local d = get_line_depth(bufnr, l)
        if d == target_depth then
          vim.api.nvim_win_set_cursor(self.win_id, { l, col })
          break
        elseif d < target_depth then
          break
        end
      end
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "gp", function()
      local cursor = vim.api.nvim_win_get_cursor(self.win_id)
      local lnum = cursor[1]
      local col = cursor[2]

      local count = get_line_depth(bufnr, lnum)
      if count > 0 then
        local target_depth = count - 1
        for l = lnum - 1, 1, -1 do
          if get_line_depth(bufnr, l) == target_depth then
            local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""
            vim.api.nvim_win_set_cursor(self.win_id, { l, math.min(col, #line) })
            break
          end
        end
      end
    end, { buffer = bufnr, silent = true })
  end

function Finder:open()
  M.clipboard.action = nil
  M.clipboard.items = {}
  M.clipboard.deleted = {}

  if util.window_is_valid(self.win_id) then
    util.window_focus(self.win_id)
    self:refresh({ force = true, recursive = true })
    return
  end

  local win_config = util.window_get_config(self.opts)

  local buf_name = H.buffer_name(self)
  self.buf_id = vim.fn.bufnr('^' .. buf_name, '$')

  if not util.buffer_is_valid(self.buf_id) then
    self.buf_id = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(self.buf_id, buf_name)
  end

  if win_config then
    self.win_id = vim.api.nvim_open_win(self.buf_id, true, win_config)
  else
    self.win_id = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.win_id, self.buf_id)
  end

  util.window_set_option(self.win_id, 'cursorline', false)
  util.window_set_option(self.win_id, 'number', false)
  util.window_set_option(self.win_id, 'relativenumber', false)

  for name, value in pairs(self.opts.buf_opts or {}) do
    util.buffer_set_option(self.buf_id, name, value)
  end

  for name, value in pairs(self.opts.win_opts or {}) do
    util.window_set_option(self.win_id, name, value)
  end

  util.buffer_set_option(self.buf_id, 'buftype', 'acwrite')
  util.buffer_set_option(self.buf_id, 'expandtab', true)
  util.buffer_set_option(self.buf_id, 'filetype', 'fyler_finder')
  util.buffer_set_option(self.buf_id, 'shiftwidth', 2)
  util.buffer_set_option(self.buf_id, 'syntax', 'fyler_finder')

  util.window_set_option(self.win_id, 'concealcursor', 'nvic')
  util.window_set_option(self.win_id, 'conceallevel', 3)
  util.window_set_option(self.win_id, 'signcolumn', 'yes')
  util.window_set_option(self.win_id, 'winfixheight', true)
  util.window_set_option(self.win_id, 'winfixwidth', true)
  util.window_set_option(self.win_id, 'wrap', false)

  for mode, keys in pairs(self.opts.mappings or {}) do
    for key, mapping in pairs(keys) do
      if type(mapping) == 'table' and not mapping.disabled then
        local opts = vim.tbl_deep_extend(
          'force',
          { noremap = true, nowait = true, silent = true },
          mapping.opts or {},
          { buffer = self.buf_id }
        )
        if type(mapping.action) == 'function' then
          vim.keymap.set(mode, key, function() mapping.action(self, mapping.args) end, opts)
        elseif type(mapping.action) == 'string' then
          local action = self[mapping.action]
          if action then vim.keymap.set(mode, key, function() action(self, mapping.args) end, opts) end
        end
      end
    end
  end

  local ag = vim.api.nvim_create_augroup('FylerFinderBuf' .. self.buf_id, { clear = true })
  local au = function(event, callback, desc)
    vim.api.nvim_create_autocmd(event, { group = ag, buffer = self.buf_id, callback = callback, desc = desc })
  end

  local buf_was_unloaded = false
  au('BufUnload', function()
    buf_was_unloaded = true
    vim.schedule(function()
      if buf_was_unloaded then
        self.win_id = nil
        extensions.run_hook('finder_close_post', self)
        self._refresh_count = nil
        self._pending_refresh = nil
        M.clipboard.action = nil
        M.clipboard.items = {}
        M.clipboard.deleted = {}
      end
    end)
  end, 'Detect buffer deletion')
  au('BufReadCmd', function()
    buf_was_unloaded = false
    self:refresh({ force = true, recursive = true })
  end, 'Ensure buffer reloads')
  au('BufWipeout', function()
    buf_was_unloaded = false
    self.win_id = nil
    extensions.run_hook('finder_close_post', self)
    self._refresh_count = nil
    self._pending_refresh = nil
    M.clipboard.action = nil
    M.clipboard.items = {}
    M.clipboard.deleted = {}
  end, 'Clean up on buffer wipeout')
  au('BufWriteCmd', function() self:mutate() end, 'Ensure buffer saves')
  au('VimResized', function() self:resize() end, 'Ensure resize')

  if self.opts.bound_cursor then
    au('CursorMoved', function()
      if not util.window_is_valid(self.win_id) then return end
      local line = vim.api.nvim_get_current_line()
      local _, id_end = line:find('/%d+ ')
      if not id_end then return end
      local pos = vim.api.nvim_win_get_cursor(self.win_id)
      if pos[2] < id_end then vim.api.nvim_win_set_cursor(self.win_id, { pos[1], id_end }) end
    end, 'Ensure cursor boundary')
  end

  setup_buffer_mappings(self)

  au({ 'CursorMoved', 'BufEnter' }, function()
    update_fyler_indent_scope(self)
  end, 'Update indent scope guides')

  au({ 'TextChanged', 'TextChangedI', 'BufEnter' }, function()
    apply_fyler_highlights(self)
    update_fyler_clipboard_highlights(self)
    update_fyler_unsaved_lines(self)
  end, 'Update highlights and unsaved lines')

  vim.cmd.tcd({ args = { vim.fn.fnameescape(self.opts.root_path) }, mods = { silent = true } })
  local target_path = vim.fn.bufname('#')
  if #target_path > 0 and self.opts.follow_current_file then
    self:follow({ target_path = target_path, force = true })
  else
    self:refresh({ force = true, recursive = true })
  end
end

function Finder:refresh(args)
  args = args or {}
  if self._is_refreshing then
    self._pending_refresh = H.merge_refresh_args(self._pending_refresh, args)
    return
  end

  self._is_refreshing = true

  local target_path = args.target_path or self.state.pseudo_root_path
  if not self.state.meta[libpath.to_key(target_path)] then
    self._is_refreshing = false
    return
  end

  self.state:update(
    target_path,
    { recursive = args.recursive, force = args.force },
    vim.schedule_wrap(function()
      if not util.buffer_is_valid(self.buf_id) then
        self._is_refreshing = false
        return
      end

      local flat = self.state:to_lines()
      local visible, hl_ns, lines = H.render_tree(self, flat)
      if args.callback then args.callback() end

      extensions.run_hook('finder_refresh_post', self, visible, hl_ns, lines, args)

      H.finish_refresh(self)

      apply_fyler_highlights(self)
      update_fyler_clipboard_highlights(self)
      update_fyler_indent_scope(self)
    end)
  )
end

function Finder:resize() util.window_resize(self.win_id, self.opts) end

---@param args { close: boolean|nil, tabedit: boolean|nil, split: boolean|nil, vsplit: boolean|nil }|nil
function Finder:select(args)
  args = args or {}

  local lnum = vim.api.nvim_win_get_cursor(self.win_id)[1]
  if lnum == 1 then
    self:visit({ parent = true })
    return
  end

  local node_data = M.parse_cursor_line(self)
  if not node_data then return end
  if node_data.type == 'directory' and vim.api.nvim_get_option_value('modified', { buf = self.buf_id }) then
    vim.cmd('write')
    return
  end
  if node_data.type == 'link' then
    vim.notify('BROKEN SYMLINK: ' .. node_data.path, vim.log.levels.WARN)
  elseif node_data.type == 'directory' then
    self.state:toggle(node_data.path)
    if self.state.meta[libpath.to_key(node_data.path)] then
      self:refresh({ target_path = node_data.path })
    else
      self:refresh({ target_path = libpath.to_dirname(node_data.path) })
    end
  else
    local edit = not (args.split or args.vsplit or args.tabedit)
    ---@return boolean
    local function get_should_close()
      if args.close then return true end
      if self.opts.kind == 'floating' then return not args.tabedit end
      if self.opts.kind == 'replace' then return edit end
      return false
    end
    local should_close = get_should_close()
    if should_close then self:close() end

    local os_path = libpath.to_os(libpath.to_abs(node_data.link or node_data.path))
    local should_goto_suitable_window = not (should_close or self.opts.kind == 'replace')
    if should_goto_suitable_window then M.window_goto_suitable(self, os_path) end

    local splitright = vim.o.splitright
    local splitbelow = vim.o.splitbelow
    vim.o.splitright = true
    vim.o.splitbelow = true

    vim.cmd[args.tabedit and 'tabedit' or args.split and 'split' or args.vsplit and 'vsplit' or 'edit']({
      args = { vim.fn.fnameescape(os_path) },
      mods = { keepalt = args.split or args.vsplit },
    })

    vim.o.splitright = splitright
    vim.o.splitbelow = splitbelow
  end
end

---@param args { parent: boolean|nil }|nil
function Finder:shrink(args)
  args = args or {}

  local node_data = M.parse_cursor_line(self)
  if not node_data then return end

  if args.parent then
    local parent_path = vim.fs.dirname(node_data.path)
    if parent_path == self.state.pseudo_root_path then return end

    local parent_node
    self.state:walk(function(node) parent_node = node end, { target_path = parent_path })

    self.state:toggle(parent_path, false)

    self:refresh({
      target_path = libpath.to_dirname(parent_path),
      callback = function()
        if not util.window_is_valid(self.win_id) then return end
        if parent_node and parent_node.value then self._view.lnum = self._id_to_line[parent_node.value] or 1 end
      end,
    })
  else
    self.state:toggle(node_data.path, false)
    self:refresh({ target_path = libpath.to_dirname(node_data.path) })
  end
end

function Finder:toggle()
  if util.window_is_valid(self.win_id) then
    self:close()
    return
  end

  self:open()
end

---@param args string[]
function Finder:toggle_ui(args)
  vim.iter(args):each(function(arg)
    if arg == 'indent_guides' then
      self.cache.ui.indent_guides = not self.cache.ui.indent_guides
    elseif arg == 'hidden_items' then
      local function toggle_dict(dict)
        for k, v in pairs(dict) do
          dict[k] = not v
        end
      end
      toggle_dict(self.cache.ui.hidden_items.switches)
      toggle_dict(self.cache.ui.hidden_items.patterns)
    end
  end)

  self:refresh()
end

---@param args { parent: boolean|nil, cursor: boolean|nil, path: string|nil }|nil
function Finder:visit(args)
  args = args or {}

  if args.parent then
    args.path = vim.fs.dirname(self.state.pseudo_root_path)
  elseif args.cursor then
    local node_data = M.parse_cursor_line(self)
    if not (node_data and node_data.type == 'directory') then return end
    args.path = node_data.path
  else
    args.path = args.path or self.state.root_path
  end

  if self.state.pseudo_root_path == args.path then return end

  -- NOTE: We need to delete the old buffer because
  -- renaming the buffer creates another buffer (don't know why?)
  local old_buf_name = H.buffer_name(self)
  self.state:change_pseudo_root(args.path)
  vim.cmd.tcd({ args = { vim.fn.fnameescape(args.path) }, mods = { silent = true } })
  vim.api.nvim_buf_set_name(self.buf_id, H.buffer_name(self))
  local old_buf_id = vim.fn.bufnr('^' .. old_buf_name .. '$')
  if util.buffer_is_valid(old_buf_id) then vim.api.nvim_buf_delete(old_buf_id, { force = true }) end
  self:refresh({ recursive = true })
end

M.instance_get = function(tab_id, opts)
  tab_id = tab_id or vim.api.nvim_get_current_tabpage()
  opts = H.normalize_opts(opts)
  if instances[tab_id] and vim.deep_equal(instances[tab_id].opts, opts) then return instances[tab_id] end
  if instances[tab_id] then instances[tab_id]:close() end
  instances[tab_id] = H.new_instance(opts)
  return instances[tab_id]
end

---@param tab_id integer|nil
---@return fyler.Finder|nil
M.instance_get_or_nil = function(tab_id)
  tab_id = tab_id or vim.api.nvim_get_current_tabpage()
  local inst = instances[tab_id]
  if inst and util.window_is_valid(inst.win_id) and util.buffer_is_valid(inst.buf_id) then return inst end
  return nil
end

---@private
---@param instance fyler.Finder
---@return fyler.FSEntry|nil
---@nodiscard
M.parse_cursor_line = function(instance)
  if not util.buffer_is_valid(instance.buf_id) then return end
  local buf_line = vim.api.nvim_buf_call(instance.buf_id, function() return vim.api.nvim_get_current_line() end)
  local id = buf_line:match('(%d+)')
  if not id then return end
  local id_int = tonumber(id, 10)
  return state.store[id_int]
end

---@param instance fyler.Finder
---@param path string
M.window_goto_suitable = function(instance, path)
  local is_popup = function(winid)
    local win_config = vim.api.nvim_win_get_config(winid)
    return win_config and (#win_config.relative > 0 or win_config.external)
  end

  local is_suitable = function(winid)
    if is_popup(winid) then return false end
    local bufnr = vim.api.nvim_win_get_buf(winid)
    return vim.bo[bufnr].filetype ~= 'fyler_finder'
  end

  local bufnr = vim.fn.bufnr(path)
  local target_win = util.buffer_is_valid(bufnr) and vim.fn.win_findbuf(bufnr)[1] or nil
  if target_win and is_suitable(target_win) then
    vim.api.nvim_set_current_win(target_win)
    return
  end

  local tab = vim.api.nvim_get_current_tabpage()
  local prior_win_id = util.window_get_prior(tab)
  if prior_win_id and vim.api.nvim_win_is_valid(prior_win_id) and is_suitable(prior_win_id) then
    vim.api.nvim_set_current_win(prior_win_id)
    return
  end

  local attempts = 0
  local initial_win = vim.api.nvim_get_current_win()
  while attempts < 5 do
    if is_suitable(vim.api.nvim_get_current_win()) then return end
    vim.cmd.wincmd('w')
    attempts = attempts + 1
  end

  vim.api.nvim_set_current_win(initial_win)

  local direction = (instance.opts.kind:match('^split_(%a+)') or ''):upper()
  if direction == 'ABOVE' then
    vim.api.nvim_command('rightbelow split')
  elseif direction == 'RIGHT' then
    vim.api.nvim_command('leftabove vsplit')
  elseif direction == 'BELOW' then
    vim.api.nvim_command('leftabove split')
  else
    vim.api.nvim_command('rightbelow vsplit')
  end

  util.window_resize(instance.win_id, instance.opts)
end

return M

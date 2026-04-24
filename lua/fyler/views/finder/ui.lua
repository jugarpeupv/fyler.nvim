local Path = require("fyler.lib.path")
local Ui = require("fyler.lib.ui")
local config = require("fyler.config")
local diagnostic = require("fyler.lib.diagnostic")
local git = require("fyler.lib.git")
local util = require("fyler.lib.util")

local Component = Ui.Component
local Text = Ui.Text
local Row = Ui.Row
local Column = Ui.Column

local COLUMN_ORDER = config.values.views.finder.columns_order

-- Returns the 9-char rwxrwxrwx permission string for a path (no type prefix).
-- Always returns exactly 9 characters so the inline column is fixed-width.
local function get_permissions(path)
  local stat = Path.new(path):lstats()
  if not stat then return "---------" end

  local mode = stat.mode
  local p = {
    (mode % 512 >= 256) and "r" or "-",
    (mode % 256 >= 128) and "w" or "-",
    (mode % 128 >= 64)  and "x" or "-",
    (mode % 64  >= 32)  and "r" or "-",
    (mode % 32  >= 16)  and "w" or "-",
    (mode % 16  >= 8)   and "x" or "-",
    (mode % 8   >= 4)   and "r" or "-",
    (mode % 4   >= 2)   and "w" or "-",
    (mode % 2   >= 1)   and "x" or "-",
  }
  return table.concat(p)
end

-- Convert a 9-char rwxrwxrwx string back to an integer mode (lower 9 bits).
-- Returns nil if the string is not exactly 9 valid permission chars.
local function perms_to_mode(perm_str, stat_type)
  if not perm_str or #perm_str ~= 9 then return nil end
  local bits = {256, 128, 64, 32, 16, 8, 4, 2, 1}
  local mode = 0
  for i = 1, 9 do
    local ch = perm_str:sub(i, i)
    local expected = (i % 3 == 0) and "x" or (i % 3 == 1) and "r" or "w"
    if ch == expected then
      mode = mode + bits[i]
    elseif ch ~= "-" then
      return nil  -- invalid character
    end
  end
  -- Preserve the file-type bits from the existing stat mode (upper bits).
  -- stat_type_bits: file=0o100000 (32768), dir=0o040000 (16384), link=0o120000 (40960)
  if stat_type then
    local upper = stat_type - (stat_type % 4096)  -- mask lower 12 bits
    mode = upper + mode
  end
  return mode
end

-- On Linux, birthtime is not reliably exposed by the kernel; fall back to ctime.
local _is_linux = vim.uv.os_uname().sysname == "Linux"
local function _creation_time(stat)
  if not stat then return 0 end
  local t = _is_linux and stat.ctime or stat.birthtime
  return t.sec + t.nsec * 1e-9
end

-- "name" (default) | "creation_time"
local sort_order = "name"

local function sort_nodes(nodes)
  table.sort(nodes, function(x, y)
    local x_is_dir = x.type == "directory"
    local y_is_dir = y.type == "directory"
    if x_is_dir and not y_is_dir then
      return true
    elseif not x_is_dir and y_is_dir then
      return false
    else
      if sort_order == "creation_time" then
        local bx = _creation_time(vim.uv.fs_stat(x.path))
        local by = _creation_time(vim.uv.fs_stat(y.path))
        -- ascending: newer items (higher time) appear first
        return bx > by
      end
      local function pad_numbers(str)
        return str:gsub("%d+", function(n) return string.format("%010d", n) end)
      end
      return pad_numbers(x.name) < pad_numbers(y.name)
    end
  end)
  return nodes
end

local function flatten_tree(node, depth, result)
  depth = depth or 0
  result = result or {}

  if not node or not node.children then return result end

  local sorted_items = sort_nodes(node.children)
  for _, item in ipairs(sorted_items) do
    table.insert(result, { item = item, depth = depth })
    if item.children and #item.children > 0 then flatten_tree(item, depth + 1, result) end
  end

  return result
end

---@return string|nil, string|nil
local function icon_and_hl(item)
  local icon, hl = config.icon_provider(item.type, item.path)
  if config.values.integrations.icon == "none" then return icon, hl end

  if item.type == "directory" then
    local icons = config.values.views.finder.icon
    local is_empty = item.open and item.children and #item.children == 0
    local is_expanded = item.open or false
    icon = is_empty and icons.directory_empty
      or (is_expanded and icons.directory_expanded or icons.directory_collapsed)
      or icon
  end

  return icon, hl
end

local function create_column_context(tag, node, flattened_entries, files_column)
  return {
    tag = tag,
    root_dir = node.path,
    entries = flattened_entries,

    get_entry_data = function(index)
      local entry = flattened_entries[index]
      if not entry then return nil end

      return {
        path = entry.item.path,
        name = entry.item.name,
        type = entry.item.type,
        depth = entry.depth,
        ref_id = entry.item.ref_id,
        item = entry.item,
      }
    end,

    get_all_paths = function()
      -- Use the symlink path (link) when available: the resolved target (path)
      -- may be outside the repository, causing git check-ignore to exit 128 and
      -- drop all gitignored highlights for the entire batch.
      return util.tbl_map(flattened_entries, function(entry) return entry.item.link or entry.item.path end)
    end,

    get_files_column = function() return files_column end,
  }
end

local M = {}

M.tag = 0
M.get_sort_order = function() return sort_order end
M.set_sort_order = function(v) sort_order = v end
M.get_permissions = get_permissions
M.perms_to_mode   = perms_to_mode

-- Cache of ref_id → highlight_group from the last completed Pass 2 (git/detail columns).
-- Used in Pass 1 to pre-apply highlights so ignored/modified files never flash as
-- unstyled text before the async git column arrives.
-- Cleared per-entry before each update so stale highlights (e.g. after git commit
-- removes staged status) don't linger.
M.highlight_cache = {}

-- NOTE: Detail columns now return data via callback instead of directly updating UI
local columns = {
  link = function(ctx, _, _next)
    local column = {}

    for i = 1, #ctx.entries do
      local entry_data = ctx.get_entry_data(i)
      if entry_data and entry_data.item.link then
        -- Read the raw symlink target (as stored, before any resolution).
        -- This gives a concise display like "dotfiles/foo/bar" rather than
        -- a full absolute resolved path.
        local target = vim.uv.fs_readlink(entry_data.item.link) or entry_data.path
        table.insert(column, Text(nil, { virt_text = { { " -> " .. target, "FylerFSLink" } }, virt_text_pos = "eol" }))
      else
        table.insert(column, Text(nil, { virt_text = { { "" } } }))
      end
    end

    _next({ column = column, highlights = {} })
  end,

  git = function(ctx, _, _next)
    git.map_entries_async(ctx.root_dir, ctx.get_all_paths(), function(entries)
      local highlights, column = {}, {}

      for i, get_entry in ipairs(entries) do
        local entry_data = ctx.get_entry_data(i)
        if entry_data then
          local name_hl = get_entry[3]
          if entry_data.type == "directory" then
            if name_hl == "FylerGitIgnored" then
              name_hl = "FylerFSIgnored"
            elseif name_hl == "FylerGitUntracked" then
              name_hl = "FylerFSDirectoryName"
            end
          end
          highlights[i] = name_hl or ((entry_data.type == "directory") and "FylerFSDirectoryName" or nil)
        end
        table.insert(column, Text(nil, { virt_text = { { get_entry[1], get_entry[2] } }, virt_text_pos = "eol" }))
      end

      _next({ column = column, highlights = highlights })
    end)
  end,

  diagnostic = function(ctx, _, _next)
    diagnostic.map_entries_async(ctx.root_dir, ctx.get_all_paths(), function(entries)
      local highlights, column = {}, {}

      for i, get_entry in ipairs(entries) do
        local entry_data = ctx.get_entry_data(i)
        if entry_data then
          local hl = get_entry[2]
          highlights[i] = hl or ((entry_data.type == "directory") and "FylerFSDirectoryName" or nil)
        end
        table.insert(column, Text(nil, { virt_text = { get_entry }, virt_text_pos = "eol" }))
      end

      _next({ column = column, highlights = highlights })
    end)
  end,

  size = function(ctx, _, _next)
    local function get_size(path)
      if Path.new(path):is_directory() then return nil end

      local stat = Path.new(path):stats()
      if not stat then return nil end

      return stat.size
    end

    local function format_size(bytes)
      if not bytes or bytes < 0 then return "     -" end

      local units = { "B", "K", "M", "G", "T" }
      local unit_index = 1
      local size = bytes

      while size >= 1024 and unit_index < #units do
        size = size / 1024
        unit_index = unit_index + 1
      end

      local formatted
      if unit_index == 1 then
        formatted = string.format("%d%s", size, units[unit_index])
      else
        formatted = string.format("%.1f%s", size, units[unit_index])
      end

      return string.format("%6s", formatted)
    end

    local highlights, column = {}, {}

    for i = 1, #ctx.entries do
      table.insert(
        column,
        Text(nil, { virt_text = { { format_size(get_size(ctx.get_entry_data(i).path)), "Comment" } }, virt_text_pos = "eol" })
      )
    end

    _next({ column = column, highlights = highlights })
  end,

  creation_time = function(ctx, _, _next)
    local column = {}
    for i = 1, #ctx.entries do
      local text = ""
      local path = ctx.get_entry_data(i).path
      local stat = vim.uv.fs_stat(path)
      if stat then
        local t = _is_linux and stat.ctime or stat.birthtime
        local dt = os.date("*t", t.sec)
        text = string.format("%02d/%02d/%02d %02d:%02d",
          dt.day, dt.month, dt.year % 100, dt.hour, dt.min)
      end
      table.insert(column, Text(nil, {
        virt_text     = { { text, "FylerPermissions" } },
        virt_text_pos = "eol",
      }))
    end

    _next({ column = column, highlights = {} })
  end,
}

local function collect_and_render_details(tag, context, files_column, oncollect)
  local results, enabled_columns = {}, {}
  local total, completed = 0, 0
  for _, column_name in ipairs(COLUMN_ORDER) do
    local cfg = config.values.views.finder.columns[column_name]
    if cfg and cfg.enabled and columns[column_name] then
      total = total + 1
      enabled_columns[column_name] = cfg
    end
  end

  if total == 0 then return end

  local function on_column_complete(column_name, column_data)
    if M.tag ~= tag then return end

    results[column_name] = column_data
    completed = completed + 1

    if completed == total then
      local all_highlights = {}
      for _, col_name in ipairs(COLUMN_ORDER) do
        local result = results[col_name]
        if result and result.highlights then
          for index, highlight in pairs(result.highlights) do
            all_highlights[index] = highlight
          end
        end
      end

      for index, highlight in pairs(all_highlights) do
        local row = files_column[index]
        if row and row.children then
          local name_component = row.children[4]
          if name_component then
            name_component.option = name_component.option or {}
            name_component.option.highlight = highlight
          end
        end
      end

      -- Update the highlight cache keyed by ref_id so Pass 1 can pre-apply these
      -- highlights on the next render, eliminating the flash of unstyled text.
      -- First clear every currently-visible entry so files whose git status has
      -- been removed (e.g. after git commit) don't keep a stale highlight.
      for _, e in ipairs(context.entries) do
        if e.item and e.item.ref_id then M.highlight_cache[e.item.ref_id] = nil end
      end
      for index, highlight in pairs(all_highlights) do
        local e = context.entries[index]
        if e and e.item and e.item.ref_id then M.highlight_cache[e.item.ref_id] = highlight end
      end

      local detail_columns = { Column(files_column) }
      for _, col_name in ipairs(COLUMN_ORDER) do
        local result = results[col_name]
        if result and result.column then
          -- Prepend two spaces to the first virt_text chunk of each entry so
          -- that the gap between the file-name column and the detail column is
          -- rendered as virtual text (zero real bytes written to the buffer).
          -- Using a real Text("  ") or a spacer Column writes actual space
          -- characters that become visible listchars trail dots.
          if #detail_columns > 0 then
            for _, entry in ipairs(result.column) do
              if entry.option and entry.option.virt_text and entry.option.virt_text[1] then
                local text = entry.option.virt_text[1][1] or ""
                if text ~= "" then
                  entry.option.virt_text[1][1] = "  " .. text
                end
              end
            end
          end

          table.insert(detail_columns, Column(result.column))
        end
      end

      oncollect({ tag = "files", children = { Row(detail_columns) } }, { partial = true })
    end
  end

  for column_name, cfg in pairs(enabled_columns) do
    local column_fn = columns[column_name]
    if column_fn then
      local success = pcall(function()
        column_fn(context, cfg, function(column_data) on_column_complete(column_name, column_data) end)
      end)

      if not success then on_column_complete(column_name, nil) end
    end
  end
end

M.files = Component.new_async(function(node, onupdate)
  M.tag = M.tag + 1

  local current_tag = M.tag
  if not node or not node.children then return onupdate({ tag = "files", children = {} }) end

  local flattened_entries = flatten_tree(node)
  if #flattened_entries == 0 then return onupdate({ tag = "files", children = {} }) end

  local perm_enabled = config.values.views.finder.columns.permission
    and config.values.views.finder.columns.permission.enabled

  local files_column = {}
  for _, entry in ipairs(flattened_entries) do
    local item, depth = entry.item, entry.depth
    local icon, hl = icon_and_hl(item)
    local icon_highlight = (item.type == "directory") and "FylerFSDirectoryIcon" or hl
    -- Use the cached highlight from the last Pass 2 if available; this ensures
    -- ignored/modified/staged files are already styled in Pass 1 so they never
    -- flash as unstyled text before the async git column arrives.
    local name_highlight = M.highlight_cache[item.ref_id]
      or ((item.type == "directory") and "FylerFSDirectoryName" or nil)
    icon = icon and (icon .. "  ") or ""

    local indentation_text = Text(string.rep(" ", 2 * depth))
    local icon_text = Text(icon, { highlight = icon_highlight })
    local ref_id_text = item.ref_id and Text(string.format("/%05d ", item.ref_id)) or Text("")
    local perm_text = perm_enabled
      and Text("  " .. get_permissions(item.link or item.path), { highlight = "FylerPermissions", priority = 200 })
      or Text("")
         local name_text = Text(item.name .. (item.type == "directory" and "/" or ""), { highlight = name_highlight })
    table.insert(files_column, Row({ indentation_text, icon_text, ref_id_text, name_text, perm_text }))
  end

  -- First pass: render the file tree immediately so the buffer is populated
  -- without waiting for async detail columns (git status, symlink targets, …).
  onupdate({ tag = "files", children = { Row({ Column(files_column) }) } })

  -- Second pass: fire detail columns in parallel. When all complete, a partial
  -- re-render overlays the virtual-text decorations without rewriting buffer lines.
  collect_and_render_details(
    current_tag,
    create_column_context(current_tag, node, flattened_entries, files_column),
    files_column,
    onupdate
  )
end)

-- Refresh only the detail columns (git, diagnostic, etc.) for the current node,
-- without rewriting buffer lines. This avoids the flicker caused by set_lines
-- when the file tree has not changed (e.g. after a git commit).
M.refresh_details = function(node, onupdate)
  M.tag = M.tag + 1
  local current_tag = M.tag

  if not node or not node.children then return end

  local flattened_entries = flatten_tree(node)
  if #flattened_entries == 0 then return end

  -- Rebuild files_column so highlights can be mutated by on_column_complete
  local perm_enabled = config.values.views.finder.columns.permission
    and config.values.views.finder.columns.permission.enabled

  local files_column = {}
  for _, entry in ipairs(flattened_entries) do
    local item, depth = entry.item, entry.depth
    local icon, hl = icon_and_hl(item)
    local icon_highlight = (item.type == "directory") and "FylerFSDirectoryIcon" or hl
    local name_highlight = (item.type == "directory") and "FylerFSDirectoryName" or nil
    icon = icon and (icon .. "  ") or ""

    local indentation_text = Text(string.rep(" ", 2 * depth))
    local icon_text = Text(icon, { highlight = icon_highlight })
    local ref_id_text = item.ref_id and Text(string.format("/%05d ", item.ref_id)) or Text("")
    local perm_text = perm_enabled
      and Text("  " .. get_permissions(item.link or item.path), { highlight = "FylerPermissions", priority = 200 })
      or Text("")
     local name_text = Text(item.name .. (item.type == "directory" and "/" or ""), { highlight = name_highlight })
    table.insert(files_column, Row({ indentation_text, icon_text, ref_id_text, name_text, perm_text }))
  end

  collect_and_render_details(
    current_tag,
    create_column_context(current_tag, node, flattened_entries, files_column),
    files_column,
    onupdate
  )
end

M.operations = Component.new(function(operations)
  local types, details = {}, {}
  for _, operation in ipairs(operations) do
    if operation.type == "create" then
      table.insert(types, Text("CREATE", { highlight = "FylerGreen" }))
      table.insert(details, Text(operation.path))
    elseif operation.type == "delete" then
      table.insert(
        types,
        Text(config.values.views.finder.delete_to_trash and "TRASH" or "DELETE", { highlight = "FylerRed" })
      )
      table.insert(details, Text(operation.path))
    elseif operation.type == "move" then
      table.insert(types, Text("MOVE", { highlight = "FylerYellow" }))
      table.insert(details, Row({ Text(operation.src), Text(" > "), Text(operation.dst) }))
    elseif operation.type == "copy" then
      table.insert(types, Text("COPY", { highlight = "FylerBlue" }))
      table.insert(details, Row({ Text(operation.src), Text(" > "), Text(operation.dst) }))
    elseif operation.type == "chmod" then
      table.insert(types, Text("CHMOD", { highlight = "FylerYellow" }))
      table.insert(details, Row({ Text(operation.path), Text(" → mode "), Text(string.format("%o", operation.mode % 512)) }))
    else
      error(string.format("Unknown operation type '%s'", operation.type))
    end
  end
  return {
    tag = "operations",
    children = {
      Text(""),
      Row({ Text("  "), Column(types), Text(" "), Column(details), Text("  ") }),
      Text(""),
    },
  }
end)

return M

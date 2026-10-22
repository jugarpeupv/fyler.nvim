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

local M = {}

-- Cache of ref_id → highlight_group from the last completed Pass 2 (git/detail columns).
-- Used in Pass 1 to pre-apply highlights so ignored/modified files never flash as
-- unstyled text before the async git column arrives.
-- Cleared per-entry before each update so stale highlights (e.g. after git commit
-- removes staged status) don't linger.
M.highlight_cache = {}

-- Per-render stat cache: at most one lstat + one stat per path per
-- refresh. Pass 1 stats each visible entry up to 4 times (permissions,
-- size, date, executable bit); without the cache a 500-entry directory
-- costs ~2000 syscalls per refresh. The cache is created fresh for every
-- M.files / refresh_details run and never outlives it, so it cannot go
-- stale across filesystem changes.
local function new_stat_cache()
  local lstats, stats = {}, {}
  return {
    lstat = function(path)
      local st = lstats[path]
      if st == nil then
        st = Path.new(path):lstats() or false
        lstats[path] = st
      end
      return st or nil
    end,
    stat = function(path)
      local st = stats[path]
      if st == nil then
        st = Path.new(path):stats() or false
        stats[path] = st
      end
      return st or nil
    end,
  }
end

-- Returns the 10-char permission string for a path, ls-style: a file-type
-- character followed by the 9 rwx bits (".rw-r--r--", "drwxr-xr-x", ...).
-- Regular files use "." (eza style). The type character comes from the same
-- stat call, no extra queries.
-- Always returns exactly 10 characters so the inline column is fixed-width.
---@param path string
---@param cache table|nil per-render stat cache from new_stat_cache()
local function get_permissions(path, cache)
  local stat = cache and cache.lstat(path) or Path.new(path):lstats()
  if not stat then return ".---------" end

  local type_char = ({
    directory = "d",
    file = ".",
    link = "l",
    fifo = "p",
    socket = "s",
    char = "c",
    block = "b",
  })[stat.type] or "?"

  local mode = stat.mode
  local p = {
    (mode % 512 >= 256) and "r" or "-",
    (mode % 256 >= 128) and "w" or "-",
    (mode % 128 >= 64) and "x" or "-",
    (mode % 64 >= 32) and "r" or "-",
    (mode % 32 >= 16) and "w" or "-",
    (mode % 16 >= 8) and "x" or "-",
    (mode % 8 >= 4) and "r" or "-",
    (mode % 4 >= 2) and "w" or "-",
    (mode % 2 >= 1) and "x" or "-",
  }
  return type_char .. table.concat(p)
end

-- Returns size in bytes straight from the stat (ls -la style: directories
-- show their own entry size, not a recursive total), or nil when missing.
-- Rendered as real buffer text (not virtual text) so it is always visible.
---@param path string
---@param cache table|nil per-render stat cache from new_stat_cache()
local function get_size_bytes(path, cache)
  local stat = cache and cache.stat(path) or Path.new(path):stats()
  if not stat then return nil end

  return stat.size
end

-- Format raw bytes humanized to a fixed 6-char width ("  512B", " 11.1K",
-- " 16.4M", "  2.6G"), or "" when there is no size to show.
local function format_size_bytes(bytes)
  if not bytes or bytes < 0 then return "" end
  if bytes < 1024 then return string.format("%6s", string.format("%dB", bytes)) end

  local units = { "K", "M", "G", "T" }
  local size, unit_index = bytes / 1024, 1
  while size >= 1024 and unit_index < #units do
    size = size / 1024
    unit_index = unit_index + 1
  end

  return string.format("%6s", string.format("%.1f%s", size, units[unit_index]))
end

-- Birthtime (ctime on Linux) as "DD/MM/YY HH:MM" (14 chars), or "".
---@param path string
---@param cache table|nil per-render stat cache from new_stat_cache()
local function format_date(path, cache)
  local stat = cache and cache.stat(path) or vim.uv.fs_stat(path)
  if not stat then return "" end
  local t = _is_linux and stat.ctime or stat.birthtime
  if not t then return "" end
  local dt = os.date("*t", t.sec)
  return string.format("%02d/%02d/%02d %02d:%02d", dt.day, dt.month, dt.year % 100, dt.hour, dt.min)
end

local function size_enabled()
  return config.values.views.finder.columns.size and config.values.views.finder.columns.size.enabled
end

local function date_enabled()
  return config.values.views.finder.columns.creation_time and config.values.views.finder.columns.creation_time.enabled
end

local function perm_enabled()
  return config.values.views.finder.columns.permission and config.values.views.finder.columns.permission.enabled
end

-- Convert a 9-char rwxrwxrwx string back to an integer mode (lower 9 bits).
-- Returns nil if the string is not exactly 9 valid permission chars.
local function perms_to_mode(perm_str, stat_type)
  if not perm_str or #perm_str ~= 9 then return nil end
  local bits = { 256, 128, 64, 32, 16, 8, 4, 2, 1 }
  local mode = 0
  for i = 1, 9 do
    local ch = perm_str:sub(i, i)
    local expected = (i % 3 == 0) and "x" or (i % 3 == 1) and "r" or "w"
    if ch == expected then
      mode = mode + bits[i]
    elseif ch ~= "-" then
      return nil -- invalid character
    end
  end
  -- Preserve the file-type bits from the existing stat mode (upper bits).
  -- stat_type_bits: file=0o100000 (32768), dir=0o040000 (16384), link=0o120000 (40960)
  if stat_type then
    local upper = stat_type - (stat_type % 4096) -- mask lower 12 bits
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

-- Memoized natural-sort key: pad_numbers is a pure function of the name,
-- so the key is computed once per distinct name instead of once per
-- comparison (O(n) instead of O(n log n) gsub allocations).
local pad_cache = {}
local function pad_numbers(str)
  local cached = pad_cache[str]
  if cached == nil then
    cached = str:gsub("%d+", function(n) return string.format("%010d", n) end)
    pad_cache[str] = cached
  end
  return cached
end

---@param nodes table[]
---@param cache table|nil per-render stat cache from new_stat_cache()
local function sort_nodes(nodes, cache)
  if sort_order == "creation_time" then
    -- Stat once per entry up front: the old code statted inside the
    -- comparator, turning every refresh into O(n log n) syscalls.
    local times = {}
    for _, n in ipairs(nodes) do
      times[n] = _creation_time(cache and cache.stat(n.path) or vim.uv.fs_stat(n.path))
    end
    table.sort(nodes, function(x, y)
      local x_is_dir = x.type == "directory"
      local y_is_dir = y.type == "directory"
      if x_is_dir and not y_is_dir then
        return true
      elseif not x_is_dir and y_is_dir then
        return false
      else
        -- ascending: newer items (higher time) appear first
        return times[x] > times[y]
      end
    end)
    return nodes
  end
  table.sort(nodes, function(x, y)
    local x_is_dir = x.type == "directory"
    local y_is_dir = y.type == "directory"
    if x_is_dir and not y_is_dir then
      return true
    elseif not x_is_dir and y_is_dir then
      return false
    else
      return pad_numbers(x.name) < pad_numbers(y.name)
    end
  end)
  return nodes
end

---@param cache table|nil per-render stat cache from new_stat_cache()
local function flatten_tree(node, depth, result, parent_ignored, cache)
  depth = depth or 0
  result = result or {}

  if not node or not node.children then return result end

  local sorted_items = sort_nodes(node.children, cache)
  for _, item in ipairs(sorted_items) do
    local is_ignored = parent_ignored
      or (item.ref_id and M.highlight_cache[item.ref_id] == "FylerFSIgnored")
      or (item.ref_id and M.highlight_cache[item.ref_id] == "FylerGitIgnored")
    table.insert(result, { item = item, depth = depth, ignored = is_ignored })
    if item.children and #item.children > 0 then flatten_tree(item, depth + 1, result, is_ignored, cache) end
  end

  return result
end

-- Glyph shown for executable files, regardless of the icon provider.
-- Written as a codepoint (not a literal) so tooling cannot mangle it.
-- U+F489 = nf-md-console. Override with views.finder.icon.executable.
local EXEC_ICON = vim.fn.nr2char(0xE795)

---Whether the entry is an executable file (any of the owner/group/other
---execute bits set). Directories are never treated as executable.
---@param item table
---@param cache table|nil per-render stat cache from new_stat_cache()
---@return boolean
local function is_executable(item, cache)
  if item.type == "directory" then return false end
  local stat = cache and cache.stat(item.link or item.path) or Path.new(item.link or item.path):stats()
  if not stat or not stat.mode then return false end
  local perm = stat.mode % 512
  return perm % 2 == 1 or math.floor(perm / 8) % 2 == 1 or math.floor(perm / 64) % 2 == 1
end

---@return string|nil, string|nil, boolean
local function icon_and_hl(item, cache)
  local icon, hl = config.icon_provider(item.type, item.path)
  if config.values.integrations.icon == "none" then return icon, hl, false end

  if item.type == "directory" then
    local icons = config.values.views.finder.icon
    local is_empty = item.open and item.children and #item.children == 0
    local is_expanded = item.open or false
    icon = is_empty and icons.directory_empty
      or (is_expanded and icons.directory_expanded or icons.directory_collapsed)
      or icon
    return icon, hl, false
  end

  if is_executable(item, cache) then
    local icons = config.values.views.finder.icon
    return icons.executable or EXEC_ICON, "FylerExecutable", true
  end

  return icon, hl, false
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

M.tag = 0
M.get_sort_order = function() return sort_order end
M.set_sort_order = function(v) sort_order = v end
M.get_permissions = get_permissions
M.perms_to_mode = perms_to_mode

-- Build one files_column Row for an entry.
-- Display order: <icon> <name> <perms> | <size> | <date>
-- (ref_id concealed). Buffer text is fully determined by Pass 1: git
-- status rides as virtual text (see columns.git), so Pass 2 never rewrites
-- buffer lines and always renders partial (extmarks only).
-- Each optional field is omitted when its column is off, leaving no gap.
-- Children indices: 1 indent, 2 icon, 3 ref_id, 4 name, 5 perms,
-- 6 size, 7 date.
---@param item table
---@param depth integer
---@param icon string
---@param icon_highlight string|nil
---@param name_highlight string|nil
---@param cache table|nil per-render stat cache from new_stat_cache()
---@return table Row component
local function build_entry_row(item, depth, icon, icon_highlight, name_highlight, cache)
  local show_perm = perm_enabled()
  local show_size = size_enabled()
  local show_date = date_enabled()
  local stat_path = item.link or item.path
  local indentation_text = Text(string.rep(" ", 2 * depth))
  local icon_text = Text(icon, { highlight = icon_highlight })
  local ref_id_text = item.ref_id and Text(string.format("/%05d ", item.ref_id), { conceal = "" }) or Text("")
  local name_text = Text(item.name .. (item.type == "directory" and "/" or ""), { highlight = name_highlight })
  local sep = "  "
  local perm_text = Text("")
  if show_perm then
    perm_text = Text(sep .. get_permissions(stat_path, cache), { highlight = "FylerPermissions", priority = 200 })
    sep = " | "
  end
  local size_text = Text("")
  if show_size then
    local size_str = format_size_bytes(get_size_bytes(stat_path, cache)):gsub("^%s+", "")
    if size_str ~= "" then
      size_text = Text(sep .. size_str, { highlight = "FylerSize" })
      sep = " | "
    end
  end
  local date_text = Text("")
  if show_date then
    local date_str = format_date(stat_path, cache)
    if date_str ~= "" then date_text = Text(sep .. date_str, { highlight = "FylerPermissions" }) end
  end
  return Row({ indentation_text, icon_text, ref_id_text, name_text, perm_text, size_text, date_text })
end

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

  -- Git status renders as virtual text at the end of the line (like the
  -- link and diagnostic columns), never as real buffer text. Pass 2 therefore
  -- only refreshes extmarks and always renders partial: buffer lines are
  -- written exactly once per refresh, in Pass 1.
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
        local symbol, icon_hl = get_entry[1], get_entry[2]
        if symbol and symbol ~= "" then
          table.insert(column, Text(nil, { virt_text = { { symbol, icon_hl } }, virt_text_pos = "eol" }))
        else
          table.insert(column, Text(nil, { virt_text = { { "" } } }))
        end
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

  -- NOTE: size is rendered as real buffer text in the files Row
  -- (see format_size_bytes), not as a virtual-text detail column, so there
  -- is intentionally no `size` entry here. The `columns.size.enabled` flag
  -- still controls whether the inline size text is shown.

  -- NOTE: creation_time is rendered as real buffer text in the files Row
  -- (see format_date), not as a virtual-text detail column, so there is
  -- intentionally no `creation_time` entry here. The
  -- `columns.creation_time.enabled` flag still controls whether the inline
  -- date text is shown.
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
        -- children: 1 indent, 2 icon, 3 ref_id, 4 name, 5 perms, 6 size, 7 date.
        local row = files_column[index]
        if row and row.children then
          local name_component = row.children[4]
          if name_component then
            -- Executable styling wins: never overwrite an executable file's
            -- name with a detail (git) highlight. is_exec was computed (and
            -- its stat cached) in Pass 1, so this costs no extra syscall.
            local entry = context.entries[index]
            if entry and not entry.is_exec then
              name_component.option = name_component.option or {}
              name_component.option.highlight = highlight
            end
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
          -- Prepend a small gap to the first virt_text chunk of each entry so
          -- that the gap between the file-name column and the detail column is
          -- rendered as virtual text (zero real bytes written to the buffer).
          -- Using a real Text("  ") or a spacer Column writes actual space
          -- characters that become visible listchars trail dots.
          local gap = "  "
          if #detail_columns > 0 and gap ~= "" then
            for _, entry in ipairs(result.column) do
              if entry.option and entry.option.virt_text and entry.option.virt_text[1] then
                local text = entry.option.virt_text[1][1] or ""
                if text ~= "" then entry.option.virt_text[1][1] = gap .. text end
              end
            end
          end

          table.insert(detail_columns, Column(result.column))
        end
      end

      -- Buffer lines are already final from Pass 1 (git is virtual text
      -- now): only extmarks are refreshed, never buffer lines.
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

  local files_column = {}
  local stat_cache = new_stat_cache()

  local flattened_entries = flatten_tree(node, nil, nil, nil, stat_cache)
  if #flattened_entries == 0 then return onupdate({ tag = "files", children = { Row({ Column(files_column) }) } }) end

  for _, entry in ipairs(flattened_entries) do
    local item, depth = entry.item, entry.depth
    local icon, hl, is_exec = icon_and_hl(item, stat_cache)
    -- Stash for Pass 2 (highlight patching) so it never re-stats.
    entry.is_exec = is_exec
    local icon_highlight = (item.type == "directory") and "FylerFSDirectoryIcon" or hl
    -- Use the cached highlight from the last Pass 2 if available; this ensures
    -- ignored/modified/staged files and directories are already styled in Pass 1
    -- so they never flash as unstyled text or reset to default directory highlight
    -- before the async git column arrives.
    -- If an entry has no direct cache entry but inherits ignored status from
    -- an ancestor, pre-apply the ignored highlight immediately.
    -- Executable styling wins over git status for names when both apply.
    local cached_hl = (item.ref_id and M.highlight_cache[item.ref_id])
      or (entry.ignored and ((item.type == "directory") and "FylerFSIgnored" or "FylerGitIgnored") or nil)
    local name_highlight = (is_exec and "FylerExecutable" or nil)
      or cached_hl
      or ((item.type == "directory") and "FylerFSDirectoryName" or nil)
    icon = icon and (icon .. "  ") or ""

    -- Display order: <icon> <name> <perms> | <size> | <date>
    -- (ref_id concealed; stats come from the per-render cache).
    table.insert(files_column, build_entry_row(item, depth, icon, icon_highlight, name_highlight, stat_cache))
  end

  -- First pass: render the file tree immediately so the buffer is populated
  -- without waiting for async detail columns (git status, symlink targets, …).
  onupdate({ tag = "files", children = { Row({ Column(files_column) }) } })

  -- Second pass: fire detail columns in parallel. All columns (including
  -- git) overlay virtual-text decorations in a single partial render:
  -- buffer lines are never rewritten here.
  collect_and_render_details(
    current_tag,
    create_column_context(current_tag, node, flattened_entries, files_column),
    files_column,
    onupdate
  )
end)

-- Refresh only the detail columns (git, diagnostic, etc.) for the current node.
-- Buffer lines are never rewritten here: git status rides as virtual text,
-- so this path only refreshes extmarks.
M.refresh_details = function(node, onupdate)
  M.tag = M.tag + 1
  local current_tag = M.tag

  if not node or not node.children then return end

  local stat_cache = new_stat_cache()
  local flattened_entries = flatten_tree(node, nil, nil, nil, stat_cache)
  if #flattened_entries == 0 then return end

  -- Rebuild files_column so highlights can be mutated by on_column_complete
  local files_column = {}

  for _, entry in ipairs(flattened_entries) do
    local item, depth = entry.item, entry.depth
    local icon, hl, is_exec = icon_and_hl(item, stat_cache)
    entry.is_exec = is_exec
    local icon_highlight = (item.type == "directory") and "FylerFSDirectoryIcon" or hl
    -- NOTE: no highlight_cache read here on purpose — the cache is cleared
    -- and rewritten below, so reading it would re-apply stale data.
    local name_highlight = ((item.type == "directory") and "FylerFSDirectoryName" or nil)
      or (is_exec and "FylerExecutable" or nil)
    icon = icon and (icon .. "  ") or ""

    -- Display order: <icon> <name> <perms> | <size> | <date>
    -- (ref_id concealed; stats come from the per-render cache).
    table.insert(files_column, build_entry_row(item, depth, icon, icon_highlight, name_highlight, stat_cache))
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
      table.insert(
        details,
        Row({ Text(operation.path), Text(" → mode "), Text(string.format("%o", operation.mode % 512)) })
      )
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

local Path = require("fyler.lib.path")
local config = require("fyler.config")
local helper = require("fyler.views.finder.helper")

local M = {}

---@param self Finder
function M.n_close(self)
  return function() self:close() end
end

---@class fyler.views.finder.actions.select_opts
---@field winpick? boolean Whether to use winpick to select the file (default: true)

-- NOTE: Dependency injection due to shared logic between select actions
---@param self Finder
---@param opener fun(path: string)
---@param opts? fyler.views.finder.actions.select_opts
local function _select(self, opener, opts)
  opts = vim.tbl_extend("force", { winpick = true, keep_open = false }, opts or {})

  -- Line 2 (vim line number) is always the "../" parent-directory navigation entry.
  -- Pressing <CR> on it navigates up one directory, matching netrw behaviour.
  if vim.fn.line(".") == 2 then
    local parent_dir = Path.new(self:getcwd()):parent():posix_path()
    if parent_dir ~= self:getcwd() then self:change_root(parent_dir):dispatch_refresh({ force_update = true }) end
    return
  end

  local ref_id = helper.parse_ref_id(vim.api.nvim_get_current_line())
  if not ref_id then return end

  local entry = self.files:node_entry(ref_id)
  if not entry then return end

  if entry.type == "directory" then
    if entry.open then
      self.files:collapse_node(ref_id)
    else
      self.files:expand_node(ref_id)
    end

    return self:dispatch_refresh({ force_update = true })
  end

  -- Close if kind=replace|float or config.values.views.finder.close_on_select is enabled.
  -- Split openers (vsplit/split) keep fyler open: closing first would wipe the
  -- fyler buffer that the split originates from, leaving an empty [No Name]
  -- pane (e.g. SelectVSplit from a single-window replace layout).
  local should_close = not opts.keep_open
    and (self.win.kind:match("^replace") or self.win.kind:match("^float") or config.values.views.finder.close_on_select)

  local function is_usable_win(winid)
    if not vim.api.nvim_win_is_valid(winid) then return false end
    if vim.api.nvim_win_get_config(winid).relative ~= "" then return false end
    if vim.wo[winid].winfixbuf then return false end
    return true
  end

  local function get_target_window()
    -- When fyler stays open (should_close=false), never target the fyler window
    -- itself — doing so would open the file inside fyler's buffer.
    local fyler_winid = not should_close and self.win.winid or nil

    if is_usable_win(self.win.origin_win) and self.win.origin_win ~= fyler_winid then return self.win.origin_win end

    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if is_usable_win(winid) and winid ~= fyler_winid then
        self.win.origin_win = winid
        return winid
      end
    end

    -- No suitable window found — return nil so open_in_window can create a new
    -- split beside fyler.
    return nil
  end

  local function open_in_window(winid)
    -- If a winid was passed in (e.g. from winpick), reject it if it's not usable
    if winid and not is_usable_win(winid) then winid = nil end
    winid = winid or get_target_window()

    local fyler_win = self.win
    local created_window = false

    -- When there is no usable window, create a new split to the right of fyler.
    -- This handles both the "stay open" case and the "close on select" case when
    -- all remaining windows have winfixbuf set (e.g. sidebar + opencode panel).
    if not winid then
      local new_buf = vim.api.nvim_create_buf(false, true)
      local fyler_width = fyler_win:config().width or math.floor(vim.o.columns * 0.25)
      local fixed_others_width = 0
      local seen_cols = {}
      ---@type table<integer, integer>  winid -> saved width
      local fixed_win_widths = {}
      for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if
          wid ~= fyler_win.winid
          and vim.api.nvim_win_is_valid(wid)
          and vim.api.nvim_win_get_config(wid).relative == ""
          and vim.wo[wid].winfixwidth
        then
          local col = vim.api.nvim_win_get_position(wid)[2]
          local w = vim.api.nvim_win_get_width(wid)
          fixed_win_widths[wid] = w
          if not seen_cols[col] then
            seen_cols[col] = true
            fixed_others_width = fixed_others_width + w + 1
          end
        end
      end
      fixed_win_widths[fyler_win.winid] = fyler_width
      local new_width = math.max(vim.o.columns - fyler_width - 1 - fixed_others_width, 1)
      local split_opts = { split = "right", width = new_width }
      if fyler_win.winid and vim.api.nvim_win_is_valid(fyler_win.winid) then split_opts.win = fyler_win.winid end
      winid = vim.api.nvim_open_win(new_buf, true, split_opts)
      local new_winid = winid
      vim.schedule(function()
        for wid, w in pairs(fixed_win_widths) do
          if vim.api.nvim_win_is_valid(wid) then vim.api.nvim_win_set_width(wid, w) end
        end
        if vim.api.nvim_win_is_valid(new_winid) then vim.api.nvim_win_set_width(new_winid, new_width) end
      end)
      created_window = true
    end

    assert(winid and vim.api.nvim_win_is_valid(winid), "Unexpected invalid window")

    if should_close then self:action_call("n_close") end

    vim.api.nvim_set_current_win(winid)

    if created_window then
      -- Window was freshly created by us — just edit the file in it directly
      -- rather than letting opener split again.
      vim.cmd.edit({
        args = { vim.fn.fnameescape(Path.new(entry.path):os_path()) },
        mods = { keepalt = false },
        bang = true,
      })
    else
      opener(entry.path)
    end
  end

  if opts.winpick then
    -- For split variants, we should pick windows
    config.winpick_provider({ self.win.winid }, open_in_window, config.winpick_opts)
  else
    open_in_window()
  end
end

---Select only when the cursorline is a directory (expand/collapse/enter).
---On files (or the "../" row) fall through to builtin `L`
---(cursor to the bottom of the window).
function M.n_select_if_directory(self)
  return function()
    local entry = self:cursor_node_entry()
    if entry and entry.type == "directory" then return M.n_select(self)() end
    vim.api.nvim_feedkeys("$", "n", false)
  end
end

function M.n_select_tab(self)
  return function()
    _select(
      self,
      function(path)
        vim.cmd.tabedit({
          args = { vim.fn.fnameescape(Path.new(path):os_path()) },
          mods = { keepalt = false },
        })
      end,
      { winpick = false }
    )
  end
end

function M.n_select_v_split(self)
  return function()
    _select(
      self,
      function(path)
        vim.cmd.vsplit({
          args = { vim.fn.fnameescape(Path.new(path):os_path()) },
          mods = { keepalt = false },
        })
      end,
      { keep_open = true }
    )
  end
end

function M.n_select_split(self)
  return function()
    _select(
      self,
      function(path)
        vim.cmd.split({
          args = { vim.fn.fnameescape(Path.new(path):os_path()) },
          mods = { keepalt = false },
        })
      end,
      { keep_open = true }
    )
  end
end

function M.n_select(self)
  return function()
    _select(
      self,
      function(path)
        vim.cmd.edit({
          args = { vim.fn.fnameescape(Path.new(path):os_path()) },
          mods = { keepalt = false },
          bang = true,
        })
      end
    )
  end
end

---@param self Finder
function M.n_collapse_all(self)
  return function()
    self.files:collapse_all()
    self:dispatch_refresh({ force_update = true })
  end
end

---@param self Finder
function M.n_goto_parent(self)
  return function()
    local parent_dir = Path.new(self:getcwd()):parent():posix_path()
    if parent_dir == self:getcwd() then return end

    -- Navigate within the tree (don't change tree root)
    self:change_root(parent_dir):dispatch_refresh({ force_update = true })
  end
end

---@param self Finder
function M.n_goto_cwd(self)
  return function()
    local pwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
    if self:getcwd() == pwd then return end
    self:change_root(pwd):dispatch_refresh({ force_update = true })
  end
end

---@param self Finder
function M.n_goto_cwd_original(self)
  return function()
    if self:getrwd() == self:getcwd() then return end
    self:change_root(self:getrwd()):dispatch_refresh({ force_update = true })
  end
end

---@param self Finder
function M.n_goto_node(self)
  return function()
    local ref_id = helper.parse_ref_id(vim.api.nvim_get_current_line())
    if not ref_id then return end

    local entry = self.files:node_entry(ref_id)
    if not entry then return end

    if entry.type == "directory" then
      -- Navigate within the tree (don't change tree root)
      self:change_root(entry.path):dispatch_refresh({ force_update = true })
    else
      self:action_call("n_select")
    end
  end
end

---@param self Finder
function M.n_collapse_node(self)
  return function()
    local ref_id = helper.parse_ref_id(vim.api.nvim_get_current_line())
    if not ref_id then return end

    local entry = self.files:node_entry(ref_id)
    if not entry then return end

    -- should not collapse root, so get it's id
    local root_ref_id = self.files.trie.value
    if entry.type == "directory" and ref_id == root_ref_id then return end

    local collapse_target = self.files:find_parent(ref_id)
    if (not collapse_target) or (not entry.open) and collapse_target == root_ref_id then return end

    local focus_ref_id
    if entry.type == "directory" and entry.open then
      self.files:collapse_node(ref_id)
      focus_ref_id = ref_id
    else
      self.files:collapse_node(collapse_target)
      focus_ref_id = collapse_target
    end

    self:dispatch_refresh({
      onrender = function()
        if self:isopen() then vim.fn.search(string.format("/%05d", focus_ref_id)) end
      end,
    })
  end
end

---@param self Finder
function M.n_set_cwd_to_parent(self)
  return function()
    local parent_dir = Path.new(self:getcwd()):parent():posix_path()
    if parent_dir == self:getcwd() then return end

    local finder_module = require("fyler.views.finder")
    finder_module.set_current_dir(parent_dir)
  end
end

---@param self Finder
function M.n_set_cwd_here(self)
  return function()
    local finder_module = require("fyler.views.finder")
    local current_cwd = finder_module.get_current_dir()

    if current_cwd == self:getcwd() then return end

    finder_module.set_current_dir(self:getcwd())
  end
end

---@param self Finder
function M.n_set_cwd_to_node(self)
  return function()
    local ref_id = helper.parse_ref_id(vim.api.nvim_get_current_line())
    if not ref_id then return end

    local entry = self.files:node_entry(ref_id)
    if not entry then return end

    local target_path
    if entry.type == "directory" then
      target_path = entry.path
    else
      -- For files, use the parent directory
      target_path = Path.new(entry.path):parent():posix_path()
    end

    local finder_module = require("fyler.views.finder")
    finder_module.set_current_dir(target_path)
  end
end

---@param self Finder
function M.n_toggle_permission(self)
  return function()
    local perm_cfg = config.values.views.finder.columns.permission
    perm_cfg.enabled = not perm_cfg.enabled
    self:dispatch_refresh({ force_update = true })
  end
end

---@param self Finder
function M.n_toggle_creation_time(self)
  return function()
    local columns = config.values.views.finder.columns
    local ctime_cfg = columns.creation_time
    if not ctime_cfg then return end
    ctime_cfg.enabled = not ctime_cfg.enabled
    self:dispatch_refresh({ force_update = true })
  end
end

---@param self Finder
function M.n_toggle_size(self)
  return function()
    local columns = config.values.views.finder.columns
    local size_cfg = columns.size
    if not size_cfg then return end
    size_cfg.enabled = not size_cfg.enabled
    self:dispatch_refresh({ force_update = true })
  end
end

---@param self Finder
function M.n_toggle_details(self)
  return function()
    -- Master toggle for all inline metadata (permissions, size, date). If
    -- any of them is shown, hide all three; if all are hidden, show all
    -- three. They are real buffer text, so flipping the flags and
    -- re-rendering is sufficient; the resolver already treats a missing
    -- suffix as "column off".
    local columns = config.values.views.finder.columns
    local perm_cfg = columns.permission
    local size_cfg = columns.size
    local date_cfg = columns.creation_time
    local target = not (
      (perm_cfg and perm_cfg.enabled)
      or (size_cfg and size_cfg.enabled)
      or (date_cfg and date_cfg.enabled)
    )
    if perm_cfg then perm_cfg.enabled = target end
    if size_cfg then size_cfg.enabled = target end
    if date_cfg then date_cfg.enabled = target end
    self:dispatch_refresh({ force_update = true })
  end
end

-- ---------------------------------------------------------------------------
-- Preview: vsplit window following the cursor (TogglePreview, `<C-p>`)
-- ---------------------------------------------------------------------------

local PREVIEW_MAX_BYTES = 256 * 1024 -- never read more than this for text preview
local PREVIEW_MAX_LINES = 200 -- max lines shown for text preview
local PREVIEW_DEBOUNCE_MS = 100 -- CursorMoved coalescing window while scrolling
local PREVIEW_IDLE_MS = 400 -- gap after which the next move renders almost immediately
local PREVIEW_IDLE_DEBOUNCE_MS = 15 -- delay when stepping slowly (user is looking)
local PREVIEW_MAX_DIR_ENTRIES = 100 -- max children listed for directories

local PREVIEW_IMAGE_EXTS = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
  bmp = true,
  ico = true,
  avif = true,
  tif = true,
  tiff = true,
  svg = true,
}

local function preview_set_lines(bufnr, lines, filetype)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  if filetype and filetype ~= "" and vim.bo[bufnr].filetype ~= filetype then
    pcall(function() vim.bo[bufnr].filetype = filetype end)
  elseif not filetype and vim.bo[bufnr].filetype ~= "" then
    vim.bo[bufnr].filetype = ""
  end
end

---Close the preview window, clear any image, wipe the scratch buffer and
---drop the cursor tracker. Safe to call when nothing is open.
---@param self Finder
function M.close_preview(self)
  local pv = self.preview
  if not pv then return end
  self.preview = nil
  if pv.au_group then pcall(vim.api.nvim_del_augroup_by_id, pv.au_group) end
  if pv.image then pcall(function() pv.image:clear() end) end
  if pv.winid and vim.api.nvim_win_is_valid(pv.winid) then pcall(vim.api.nvim_win_close, pv.winid, true) end
  if pv.bufnr and vim.api.nvim_buf_is_valid(pv.bufnr) then
    pcall(vim.api.nvim_buf_delete, pv.bufnr, { force = true })
  end
end

local function preview_show_dir(pv, path)
  if pv.image then
    pcall(function() pv.image:clear() end)
    pv.image = nil
  end
  local entries = {}
  local fs = vim.uv.fs_scandir(path)
  if fs then
    while #entries < PREVIEW_MAX_DIR_ENTRIES do
      local name, fs_type = vim.uv.fs_scandir_next(fs)
      if not name then break end
      table.insert(entries, name .. (fs_type == "directory" and "/" or ""))
    end
  end
  table.sort(entries)
  if #entries == 0 then entries = { "[empty directory]" } end
  preview_set_lines(pv.bufnr, entries)
end

local function preview_show_text(pv, path)
  if pv.image then
    pcall(function() pv.image:clear() end)
    pv.image = nil
  end
  local lines
  local stat = vim.uv.fs_stat(path)
  if not stat then
    lines = { "[cannot stat file]" }
  elseif stat.size > PREVIEW_MAX_BYTES then
    lines = { string.format("[file too large: %d bytes]", stat.size) }
  else
    -- Binary sniff on the first chunk before reading text.
    local is_binary = false
    local fd = vim.uv.fs_open(path, "r", 438)
    if fd then
      local data = vim.uv.fs_read(fd, 8192, 0)
      vim.uv.fs_close(fd)
      if data and data:find("\0", 1, true) then is_binary = true end
    end
    if is_binary then
      lines = { "[binary file]" }
    else
      local ok, read = pcall(vim.fn.readfile, path, "", PREVIEW_MAX_LINES)
      if ok and read and #read > 0 then
        lines = read
      else
        lines = { "[empty file]" }
      end
    end
  end
  local ft = vim.filetype.match({ filename = path })
  preview_set_lines(pv.bufnr, lines, ft)
end

local function preview_show_image(pv, winid, path)
  local ok_api, image_api = pcall(require, "image")
  if not ok_api or not image_api or not image_api.from_file then
    if pv.image then
      pcall(function() pv.image:clear() end)
      pv.image = nil
    end
    preview_set_lines(pv.bufnr, { "[image preview needs image.nvim enabled]" })
    return
  end
  -- Blank the text first; the image renders on top of the buffer area.
  preview_set_lines(pv.bufnr, {})
  if pv.image then
    pcall(function() pv.image:clear() end)
    pv.image = nil
  end
  local ok_img, img = pcall(image_api.from_file, path, { window = winid, buffer = pv.bufnr, x = 0, y = 0 })
  if not ok_img or not img then
    preview_set_lines(pv.bufnr, { "[cannot preview image]" })
    return
  end
  local ok_render = pcall(function() img:render() end)
  if not ok_render then
    preview_set_lines(pv.bufnr, { "[cannot preview image]" })
    return
  end
  pv.image = img
end

local function preview_is_image(path)
  local ext = path:match("%.([^./]+)$")
  return ext and PREVIEW_IMAGE_EXTS[ext:lower()] or false
end

---Render the entry under the cursor into an already-open preview window.
---@param self Finder
local function preview_update(self)
  local pv = self.preview
  if not pv then return end
  if not (pv.winid and vim.api.nvim_win_is_valid(pv.winid)) then
    -- Preview was closed manually (e.g. :q): drop state on next tick so we
    -- never delete an augroup from inside its own callback.
    vim.schedule(function() M.close_preview(self) end)
    return
  end
  local entry = self:cursor_node_entry()
  if not entry then
    -- Header/"../" row: show the current directory listing.
    preview_show_dir(pv, self:getcwd())
    return
  end
  local path = entry.link or entry.path
  if entry.type == "directory" then
    preview_show_dir(pv, path)
  elseif preview_is_image(path) then
    preview_show_image(pv, pv.winid, path)
  else
    preview_show_text(pv, path)
  end
end

---@param self Finder
function M.n_toggle_preview(self)
  return function()
    if self.preview and self.preview.winid and vim.api.nvim_win_is_valid(self.preview.winid) then
      M.close_preview(self)
      return
    end
    -- Drop stale state (e.g. preview was closed manually) without touching windows.
    if self.preview then
      local pv = self.preview
      self.preview = nil
      if pv.au_group then pcall(vim.api.nvim_del_augroup_by_id, pv.au_group) end
      if pv.image then pcall(function() pv.image:clear() end) end
    end
    if not (self.win and self.win:has_valid_winid() and self.win:has_valid_bufnr()) then return end
    vim.cmd("vsplit")
    local winid = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.wo[winid].number = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].winfixwidth = true
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false
    pcall(vim.api.nvim_buf_set_name, bufnr, "[fyler-preview:" .. bufnr .. "]")
    self.preview = { winid = winid, bufnr = bufnr, image = nil, gen = 0 }
    local group = vim.api.nvim_create_augroup("fyler_preview_" .. bufnr, { clear = true })
    self.preview.au_group = group
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = group,
      buffer = self.win.bufnr,
      callback = function()
        local pv = self.preview
        if not pv then return end
        pv.gen = pv.gen + 1
        local gen = pv.gen
        -- Adaptive debounce: when stepping slowly (idle gap behind us) the
        -- image conversion (~0.2-0.9s for photos) dominates anyway, so start
        -- almost immediately; while scrolling fast, coalesce so intermediate
        -- conversions never start. Stale generations are always dropped.
        local now = vim.uv.hrtime()
        local delay = ((now - (pv.last_kick or 0)) / 1e6 > PREVIEW_IDLE_MS) and PREVIEW_IDLE_DEBOUNCE_MS
          or PREVIEW_DEBOUNCE_MS
        pv.last_kick = now
        vim.defer_fn(function()
          if not self.preview or self.preview.gen ~= gen then return end
          pcall(preview_update, self)
        end, delay)
      end,
    })
    preview_update(self)
    -- Return focus to fyler so motion keys keep working.
    if self.win:has_valid_winid() then vim.api.nvim_set_current_win(self.win.winid) end
  end
end

-- Descriptions for the keymap help popup (mirrors doc/fyler.txt).
local HELP_DESCS = {
  CloseView = "Close the finder window",
  CollapseAll = "Collapse all open directory nodes",
  CollapseNode = "Collapse the directory node under the cursor",
  GotoCwd = "Go to the current working directory",
  GotoCwdOriginal = "Go back to the original working directory",
  GotoNode = "Go to the node under the cursor",
  GotoParent = "Go to the parent directory",
  OpenSecondaryHSplit = "Open secondary instance in a horizontal split",
  OpenSecondaryVSplit = "Open secondary instance in a vertical split",
  PasteEntry = "Paste yanked/cut entries here",
  Select = "Open file or toggle directory expand/collapse",
  SelectIfDirectory = "Like Select on directories, builtin motion otherwise",
  SelectSplit = "Open file in a horizontal split",
  SelectTab = "Open file in a new tab",
  SelectVSplit = "Open file in a vertical split",
  SetCwdHere = "Set cwd to the directory under the cursor",
  SetCwdToNode = "Set cwd to the node under the cursor",
  SetCwdToParent = "Set cwd to the parent directory",
  ShowHelp = "Show this keymap help",
  SortByCreationTime = "Toggle sort by creation time",
  ToggleCreationTime = "Toggle the inline date column on/off",
  ToggleDetails = "Toggle all inline metadata (permissions, size, date) on/off",
  TogglePermissions = "Toggle the inline permissions column on/off",
  ToggleSize = "Toggle the inline size text on/off",
  TogglePreview = "Toggle a vsplit preview following the cursor",
  VisualCutEntries = "Cut visual selection entries",
  VisualYankEntries = "Yank visual selection entries",
}

---Show a floating pane with the available keymaps, including user custom
---ones (plain functions render as "user custom func"). Non-focusable;
---dismissed on the next cursor move, buffer leave, or re-invocation.
---@param self Finder
function M.n_show_help(self)
  return function()
    local function close_help()
      local prev = self.help_popup
      self.help_popup = nil
      if not prev then return end
      if prev.win and vim.api.nvim_win_is_valid(prev.win) then pcall(vim.api.nvim_win_close, prev.win, true) end
      if prev.buf and vim.api.nvim_buf_is_valid(prev.buf) then
        pcall(vim.api.nvim_buf_delete, prev.buf, { force = true })
      end
    end
    close_help()

    local rows = {}
    local function push(key, def)
      if type(def) == "function" then
        table.insert(rows, { key = key, desc = "user custom func" })
      elseif type(def) == "string" then
        table.insert(rows, { key = key, desc = HELP_DESCS[def] or def })
      end
    end
    for key, def in pairs(config.values.views.finder.mappings or {}) do
      if type(def) == "table" then
        local n, x = def.n, def.x or def.visual
        if n ~= nil and x ~= nil then
          push(key .. " (n)", n)
          push(key .. " (x)", x)
        elseif n ~= nil or x ~= nil then
          push(key, n or x)
        else
          table.insert(rows, { key = key, desc = "user custom func" })
        end
      else
        push(key, def)
      end
    end
    table.sort(rows, function(a, b) return a.key < b.key end)

    local key_w = 3
    for _, r in ipairs(rows) do
      key_w = math.max(key_w, vim.fn.strdisplaywidth(r.key))
    end
    local lines, width = {}, 0
    for _, r in ipairs(rows) do
      local line = " " .. r.key .. string.rep(" ", key_w - vim.fn.strdisplaywidth(r.key) + 2) .. r.desc .. " "
      table.insert(lines, line)
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    if #lines == 0 then return end
    width = math.min(width, vim.o.columns - 4)
    local height = math.min(#lines, math.max(vim.o.lines - 6, 1))

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    local winid = vim.api.nvim_open_win(bufnr, false, {
      relative = "editor",
      width = width,
      height = height,
      row = math.max(math.floor((vim.o.lines - height) / 2), 0),
      col = math.max(math.floor((vim.o.columns - width) / 2), 0),
      style = "minimal",
      border = "rounded",
      title = " Fyler keymaps ",
      title_pos = "left",
      focusable = false,
      noautocmd = true,
      zindex = 60,
    })
    self.help_popup = { win = winid, buf = bufnr }
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
      buffer = self.win.bufnr,
      once = true,
      callback = close_help,
    })
  end
end

function M.n_sort_creation_time(self)
  return function()
    local ui = require("fyler.views.finder.ui")
    if ui.get_sort_order() == "creation_time" then
      ui.set_sort_order("name")
    else
      ui.set_sort_order("creation_time")
    end
    self:dispatch_refresh({ force_update = true })
  end
end

---@param self Finder
function M.n_open_secondary_vsplit(_self)
  return function()
    local finder_mod = require("fyler.views.finder")

    -- Find the first non-fyler, non-floating editor window.
    local editor_win = nil
    for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(wid) then
        local cfg = vim.api.nvim_win_get_config(wid)
        local ft = vim.bo[vim.api.nvim_win_get_buf(wid)].filetype
        if cfg.relative == "" and ft ~= "fyler" then
          editor_win = wid
          break
        end
      end
    end

    -- vsplit the editor window (or current window as fallback), then open
    -- the secondary finder into the new split with replace kind so it sits
    -- exactly in that half of the editor area.
    local target_win
    if editor_win then vim.api.nvim_set_current_win(editor_win) end
    vim.cmd("vsplit")
    target_win = vim.api.nvim_get_current_win()

    finder_mod.open_secondary_in_win(target_win)
  end
end

---@param self Finder
function M.n_open_secondary_split(_self)
  return function()
    local finder_mod = require("fyler.views.finder")

    -- Find the first non-fyler, non-floating editor window.
    local editor_win = nil
    for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(wid) then
        local cfg = vim.api.nvim_win_get_config(wid)
        local ft = vim.bo[vim.api.nvim_win_get_buf(wid)].filetype
        if cfg.relative == "" and ft ~= "fyler" then
          editor_win = wid
          break
        end
      end
    end

    if editor_win then vim.api.nvim_set_current_win(editor_win) end
    vim.cmd("split")
    local target_win = vim.api.nvim_get_current_win()

    finder_mod.open_secondary_in_win(target_win)
  end
end

-- ---------------------------------------------------------------------------
-- Clipboard: visual yank / visual cut / paste
-- ---------------------------------------------------------------------------

---Collect paths from the visual line selection and write them to the
---fyler clipboard. action = "copy"|"move".
---@param self Finder
---@param action "copy"|"move"
local function v_collect(self, action)
  -- When the keymap fires from visual mode the '</'> marks may not be set yet
  -- (first ever visual selection in this buffer). Read the live cursor and "v"
  -- anchor positions instead, which are always valid while in visual mode.
  local cur = vim.fn.line(".")
  local anch = vim.fn.line("v")
  local first = math.min(cur, anch)
  local last = math.max(cur, anch)

  -- Lines 1 (cwd header) and 2 ("../") are not file entries. If the selection
  -- touches either of them, fall back to a plain yank and do nothing fyler-specific.
  if first <= 2 then
    -- Let Neovim handle the yank natively: feed <Esc> to finalise the visual
    -- selection marks ('<,'>), then gvy to reselect and yank into unnamed register.
    local keys = vim.api.nvim_replace_termcodes("<Esc>gvy", true, false, true)
    vim.api.nvim_feedkeys(keys, "nx", false)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(self.win.bufnr, first - 1, last, false)

  local clipboard = require("fyler.views.finder.clipboard")
  clipboard.clear(self)
  self.clipboard = { action = action, paths = {} }

  local any = false
  for _, line in ipairs(lines) do
    local ref_id = helper.parse_ref_id(line)
    if ref_id then
      local entry = self.files:node_entry(ref_id)
      if entry then
        self.clipboard.paths[entry.link or entry.path] = true
        any = true
      end
    end
  end

  if any then
    clipboard.flush(self)
    local label = action == "move" and "Cut" or "Yanked"
    local names = vim.tbl_keys(self.clipboard.paths)
    table.sort(names)
    local display = vim.tbl_map(function(p) return vim.fs.basename(p) end, names)
    vim.notify(
      string.format("[Fyler] %s %d file(s): %s", label, #display, table.concat(display, ", ")),
      vim.log.levels.INFO
    )
  end

  -- Exit visual mode in the next tick so the mode-change redraw doesn't
  -- clear the notification message that was just queued above.
  vim.schedule(function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "nx", false)
  end)
end

---@param self Finder
function M.v_yank(self)
  return function() v_collect(self, "copy") end
end

---@param self Finder
function M.v_cut(self)
  return function() v_collect(self, "move") end
end

---@param self Finder
function M.n_paste(self)
  return function()
    local clipboard = require("fyler.views.finder.clipboard")
    local async = require("fyler.lib.async")

    async.void(function()
      local payload = clipboard.read()
      if not payload or #payload.paths == 0 then return end

      -- Determine target directory from cursor position:
      -- If cursor is on a directory, paste into that directory; otherwise paste into the parent
      local entry = self:cursor_node_entry()
      local cwd
      if entry then
        if entry.type == "directory" then
          cwd = Path.new(entry.path):posix_path()
        else
          cwd = Path.new(entry.path):parent():posix_path()
        end
      else
        cwd = self:getcwd()
      end

      -- Build operations
      local operations = {}
      for _, src in ipairs(payload.paths) do
        local name = vim.fs.basename(src)
        local dst = Path.new(cwd):join(name):posix_path()
        table.insert(operations, {
          type = payload.action == "move" and "move" or "copy",
          src = src,
          dst = dst,
        })
      end

      if vim.tbl_isempty(operations) then return end

      -- Show confirmation dialog (always — mirrors the existing mutation pattern)
      local relative_cwd = Path.new(cwd)
      local display_ops = vim.tbl_map(function(op)
        local result = vim.deepcopy(op)
        result.src = relative_cwd:relative(op.src) or op.src
        result.dst = op.dst
        return result
      end, operations)

      local get_confirmation = async.wrap(vim.schedule_wrap(function(...) require("fyler.input").confirm.open(...) end))

      local confirmed = get_confirmation(require("fyler.views.finder.ui").operations(display_ops))
      if not confirmed then return end

      -- Execute sequentially, same pattern as run_mutation
      local fs = require("fyler.lib.fs")
      local spinner = require("fyler.lib.spinner").new(string.format("Pasting (0/%d)", #operations))
      spinner:start()

      local run = async.wrap(function(op, _next)
        fs[op.type](op, _next)
        return op.dst
      end)

      for i, op in ipairs(operations) do
        local err = run(op)
        if err then vim.schedule_wrap(vim.notify)(tostring(err), vim.log.levels.ERROR, { title = "Fyler" }) end
        spinner:set_text(string.format("Pasting (%d/%d)", i, #operations))
      end

      spinner:stop()

      clipboard.clear(self)

      -- Refresh every open fyler instance whose root is at or above the paste
      -- destination, so that any visible instance (e.g. the original when pasting
      -- from a secondary) immediately shows the new files.
      local dsts = vim.tbl_map(function(op) return op.dst end, operations)
      local finder_mod = require("fyler.views.finder")
      vim.schedule(function()
        for inst in finder_mod.iter_instances() do
          if inst and inst:isopen() then
            local inst_cwd = inst:getcwd()
            local should_refresh = false
            for _, dst in ipairs(dsts) do
              if dst:sub(1, #inst_cwd) == inst_cwd then
                should_refresh = true
                break
              end
            end
            if should_refresh then inst:dispatch_refresh({ force_update = true }) end
          end
        end
      end)

      -- Report full destination paths
      vim.schedule(
        function()
          vim.notify(
            string.format("[Fyler] Pasted %d file(s):\n%s", #dsts, table.concat(dsts, "\n")),
            vim.log.levels.INFO
          )
        end
      )
    end)
  end
end

return M

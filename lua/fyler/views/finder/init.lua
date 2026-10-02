local Path = require("fyler.lib.path")
local async = require("fyler.lib.async")
local config = require("fyler.config")
local helper = require("fyler.views.finder.helper")
local manager = require("fyler.views.finder.files.manager")
local util = require("fyler.lib.util")

local M = {}

-- Global CWD tracking for Fyler (initialized when finder is created)
local global_cwd = nil

-- Instance registry: slot (integer) → Finder object.
-- Declared here so all Finder methods defined below can close over it.
local MAX_INSTANCES = 2
local ORIG_SLOT     = 1
local instances     = {}

---Internal helper to update global CWD during navigation (for winbar sync)
---@param path string
local function update_global_cwd(path)
  local p = Path.new(path):posix_path()
  -- Always expand to absolute path so relative paths like "." are resolved
  global_cwd = vim.fn.fnamemodify(p, ":p"):gsub("/$", "")
end

---@class Finder
---@field uri string
---@field files Files
---@field watcher Watcher
local Finder = {}
Finder.__index = Finder

function Finder.new(uri, slot)
  local rwd, _ = helper.parse_protocol_uri(uri)
  return setmetatable({ uri = uri, rwd = rwd, slot = slot or 1 }, Finder)
end

---@param name string
function Finder:action(name)
  local action = require("fyler.views.finder.actions")[name]
  return assert(action, string.format("action %s is not available", name))(self)
end

---@param user_mappings table<string, function>
---@return table<string, function>
function Finder:action_wrap(user_mappings)
  local actions = {}
  for keys, fn in pairs(user_mappings) do
    actions[keys] = function() fn(self) end
  end
  return actions
end

---@param name string
---@param ... any
function Finder:action_call(name, ...) self:action(name)(...) end

---@deprecated
function Finder:exec_action(...)
  vim.notify("'exec_action' is deprecated use 'call_action'")
  self:action_call(...)
end

---@param kind WinKind|nil
function Finder:isopen(kind)
  if not self.win then return false end
  if kind and self.win.kind ~= kind then return false end
  if not self.win:has_valid_winid() then return false end
  if not self.win:has_valid_bufnr() then return false end
  -- Guard against recycled winid/bufnr: verify the window is actually showing
  -- the fyler buffer (by name). Without this check, a freed winid/bufnr that
  -- was recycled by Neovim for another window/buffer would cause isopen() to
  -- return true when fyler is actually closed, making toggle a no-op on the
  -- first press after close.
  if self.win:winbuf() ~= self.win.bufnr then return false end
  if vim.api.nvim_buf_get_name(self.win.bufnr) ~= self.win.bufname then return false end
  return true
end

---@param kind WinKind
function Finder:open(kind)
  local indent = require("fyler.views.finder.indent")

  local rev_maps = config.rev_maps("finder")
  local usr_maps = config.usr_maps("finder")
  local view_cfg = config.view_cfg("finder", kind)

  -- stylua: ignore start
  self.win = require("fyler.lib.win").new {
    autocmds      = {
      ["BufReadCmd"] = function()
        -- :e / :edit should reload instead of leaving buffer blank.
        if self.files and self.win and self.win:has_valid_bufnr() then
          if vim.api.nvim_buf_line_count(self.win.bufnr) == 0 then
            pcall(vim.api.nvim_buf_set_lines, self.win.bufnr, 0, -1, false, { self.win.header or self:getcwd() })
          end
        end
        self:dispatch_refresh({ force_update = true })
      end,
      ["BufWriteCmd"] = function()
        self:dispatch_mutation()
      end,
      [{"CursorMoved","CursorMovedI"}] = (function()
        local _busy = false
        return function()
          if self.win and self.win:has_valid_winid() then
            pcall(vim.api.nvim_set_option_value, "conceallevel", 3, { win = self.win.winid })
            pcall(vim.api.nvim_set_option_value, "concealcursor", "nvic", { win = self.win.winid })
          end
          if _busy then return end
          local cur = vim.api.nvim_get_current_line()
          local ref_id = helper.parse_ref_id(cur)
          if not ref_id then return end

          local _, ub = string.find(cur, string.format("/%05d ", ref_id))
          if not ub then return end
          if not self.win:has_valid_winid() then return end

          local row, col = self.win:get_cursor()
          if not (row and col) then return end

          -- ub is 1-indexed (from string.find); col is 0-indexed (from nvim_win_get_cursor).
          -- The first editable character is at 0-indexed column `ub` (i.e. 1-indexed `ub + 1`).
          if col < ub then
            _busy = true
            self.win:set_cursor(row, ub)
            _busy = false
          end
        end
      end)(),
    },
    border        = view_cfg.win.border,
    bufname       = self.uri,
    bottom        = view_cfg.win.bottom,
    buf_opts      = view_cfg.win.buf_opts,
    enter         = true,
    footer        = view_cfg.win.footer,
    footer_pos    = view_cfg.win.footer_pos,
    height        = view_cfg.win.height,
    kind          = kind,
    left          = view_cfg.win.left,
    mappings      = {
      [rev_maps["CloseView"]]         = self:action "n_close",
      [rev_maps["CollapseAll"]]        = self:action "n_collapse_all",
      [rev_maps["CollapseNode"]]       = self:action "n_collapse_node",
      [rev_maps["GotoCwd"]]            = self:action "n_goto_cwd",
      [rev_maps["GotoCwdOriginal"]]    = self:action "n_goto_cwd_original",
      [rev_maps["GotoNode"]]           = self:action "n_goto_node",
      [rev_maps["GotoParent"]]         = self:action "n_goto_parent",
      [rev_maps["Select"]]             = self:action "n_select",
      [rev_maps["SelectIfDirectory"]] = self:action "n_select_if_directory",
      [rev_maps["SelectSplit"]]        = self:action "n_select_split",
      [rev_maps["SelectTab"]]          = self:action "n_select_tab",
      [rev_maps["SelectVSplit"]]       = self:action "n_select_v_split",
      [rev_maps["TogglePermissions"]]       = self:action "n_toggle_permission",
      [rev_maps["TogglePreview"]]           = self:action "n_toggle_preview",
      [rev_maps["ToggleDetails"]]           = self:action "n_toggle_details",
      [rev_maps["PasteEntry"]]              = self:action "n_paste",
      [rev_maps["SortByCreationTime"]]      = self:action "n_sort_creation_time",
      [rev_maps["GotoCwdOriginal"]]         = self:action "n_goto_cwd_original",
      [rev_maps["OpenSecondaryVSplit"]]     = self:action "n_open_secondary_vsplit",
      [rev_maps["OpenSecondaryHSplit"]]     = self:action "n_open_secondary_split",
    },
    mappings_opts = view_cfg.mappings_opts,
    on_show       = function()
      self.watcher:enable()
      indent.attach(self.win)

      -- Set the editable path header (line 1 of the buffer)
      self.win.header = vim.fn.fnamemodify(self:getcwd(), ":~")

      local bufnr = self.win.bufnr
      local mopts = vim.tbl_extend("force", view_cfg.mappings_opts or {}, { buffer = bufnr })

      -- <CR> on the header line: read the text, resolve it and change root.
      -- On any other line, <CR> is not mapped (falls through to default).
      vim.keymap.set("n", "<CR>", function()
        if not self.win:has_valid_bufnr() then return end
        local row = vim.api.nvim_win_get_cursor(self.win.winid or 0)[1]
        if row ~= 1 then return end

        local text = vim.trim(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or "")
        local path = vim.fn.expand(text)
        path = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")

        if vim.fn.isdirectory(path) == 0 then
          vim.notify("[Fyler] Not a directory: " .. text, vim.log.levels.WARN)
          self.win:set_header(vim.fn.fnamemodify(self:getcwd(), ":~"))
          return
        end

        self:change_root(path):dispatch_refresh({ force_update = true })
      end, mopts)

      -- Smart `b`: from the filename start, jump to the previous line's
      -- size ("  1146B") instead of landing inside the concealed /NNNNN
      -- ref_id (which CursorMoved would just push back out of, making `b`
      -- a no-op). Anywhere else, or with a count, falls back to builtin `b`.
      -- Skipped when the user mapped `b` themselves or the size column is off.
      do
        local size_on = config.values.views.finder.columns.size
          and config.values.views.finder.columns.size.enabled
        local user_b = view_cfg.mappings and view_cfg.mappings["b"]
        if size_on and not user_b then
          vim.keymap.set("n", "b", function()
            local function fallback(count)
              vim.api.nvim_feedkeys((count > 0 and count or "") .. "b", "n", false)
            end
            if vim.v.count > 0 then return fallback(vim.v.count) end
            if not self.win:has_valid_winid() then return end
            local row, col = self.win:get_cursor()
            if not (row and col) then return end
            local cur = vim.api.nvim_get_current_line()
            local ref_id = helper.parse_ref_id(cur)
            if not ref_id then return fallback(0) end
            local _, ub = string.find(cur, string.format("/%05d ", ref_id))
            if not ub then return fallback(0) end
            -- Only hijack at (or inside) the leading technical zone;
            -- `ub` is the 1-indexed end of "/NNNNN ", i.e. the 0-indexed
            -- column of the first filename character.
            if col > ub then return fallback(0) end
            local prev = row - 1
            if prev < 1 then return end
            local prev_line = vim.api.nvim_buf_get_lines(bufnr, prev - 1, prev, false)[1]
            if not prev_line then return fallback(0) end
            -- `.*` backtracks from the end, so `.*()%d+` would stop at
            -- the last digit; requiring the preceding space anchors the
            -- capture at the first digit of the size ("  991B" -> "|991B").
            local ds = prev_line:match(".*%s()%d+B%s*$")
            if not ds then return fallback(0) end
            self.win:set_cursor(prev, ds - 1)
          end, mopts)
        end
      end

      -- Visual-mode actions: registered as "x" so they capture the line range
      -- from the visual selection. Cannot go through the normal mappings table
      -- which is hardcoded to "n" mode.
      local v_maps = {
        VisualYankEntries = self:action("v_yank"),
        VisualCutEntries  = self:action("v_cut"),
      }
      local rv = config.rev_maps("finder")
      for action_name, fn in pairs(v_maps) do
        local keys = rv[action_name]
        if type(keys) == "table" then
          for _, k in ipairs(keys) do
            vim.keymap.set("x", k, fn, mopts)
          end
        end
      end
    end,
    on_hide       = function()
      self.watcher:disable()
      indent.detach(self.win)
    end,
    render        = function()
      if not config.values.views.finder.follow_current_file then
        return self:dispatch_refresh({ force_update = true })
      end

      local bufname = vim.fn.bufname("#")
      if bufname == "" then
        return self:dispatch_refresh({ force_update = true })
      end

      if helper.is_protocol_uri(bufname) then
        return self:dispatch_refresh({ force_update = true })
      end

      return M.navigate(bufname, { force_update = true })
    end,
    right         = view_cfg.win.right,
    title         = string.format(" %s ", self:getcwd()),
    title_pos     = view_cfg.win.title_pos,
    top           = view_cfg.win.top,
    user_autocmds = {
      ["DispatchRefresh"] = function()
        self:dispatch_refresh({ force_update = true })
      end,
    },
    user_mappings = self:action_wrap(usr_maps),
    width         = view_cfg.win.width,
    min_width     = view_cfg.win.min_width or (type(view_cfg.win.width) == "number" and view_cfg.win.width or nil),
    win_opts      = view_cfg.win.win_opts,
  }
  -- stylua: ignore end

  self.win:show()

  -- Free the instance slot when the window is closed by any means (:q, ZZ, etc.)
  -- so that next_secondary_slot() correctly sees the slot as available.
  if self.slot ~= ORIG_SLOT and self.win:has_valid_winid() then
    local winid = self.win.winid
    local slot  = self.slot
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern  = tostring(winid),
      once     = true,
      callback = function()
        if instances[slot] and instances[slot].win and instances[slot].win.winid == winid then
          instances[slot] = nil
        end
      end,
    })
  end
end

---@return string
function Finder:getrwd() return self.rwd end

---@return string
function Finder:getcwd() return Path.new(assert(self.files, "files is required").root_path):os_path() end

function Finder:cursor_node_entry()
  local entry
  vim.api.nvim_win_call(self.win.winid, function()
    local ref_id = helper.parse_ref_id(vim.api.nvim_get_current_line())
    if ref_id then entry = vim.deepcopy(self.files:node_entry(ref_id)) end
  end)
  return entry
end

function Finder:close()
  require("fyler.views.finder.clipboard").clear(self)
  require("fyler.views.finder.actions").close_preview(self)
  if self.win then self.win:hide() end
  -- Free the slot so it can be reused by the next secondary
  if self.slot and self.slot ~= 1 then
    instances[self.slot] = nil
  end
end

function Finder:navigate(...) self.files:navigate(...) end

-- Change `self.files` instance to provided directory path
---@param path string
function Finder:change_root(path)
  assert(path, "cannot change directory without path")
  assert(Path.new(path):is_directory(), "cannot change to non-directory path")

  require("fyler.views.finder.clipboard").clear(self)
  self.watcher:disable(true)
  self.files = require("fyler.views.finder.files").new({
    open = true,
    name = Path.new(path):basename(),
    path = Path.new(path):posix_path(),
    finder = self,
  })

  -- Update the finder's URI to match the new path (but don't change buffer name)
  local normalized_path = vim.fn.fnamemodify(Path.new(path):posix_path(), ":p"):gsub("/$", "")
  self.uri = helper.build_protocol_uri(normalized_path, self.slot)
  
  -- Update the window title
  if self.win then 
    self.win:update_title(string.format(" %s ", Path.new(path):os_path()))
    self.win:set_header(vim.fn.fnamemodify(Path.new(path):os_path(), ":~"))
  end
  
  -- Update global CWD only for the original instance so secondary
  -- navigations do not mutate the global / leak into other buffers.
  if self.slot == ORIG_SLOT then
    update_global_cwd(normalized_path)
  end

  -- Restart the git watcher for the new directory.  disable(true) above stopped
  -- and cleared all watchers; start_git() resolves the new git dir from the
  -- updated self.files root and creates fresh fs_event handles.
  self.watcher:start_git()

  return self
end

---@param opts { force_update: boolean, git_only: boolean, onrender: function }|nil
function Finder:dispatch_refresh(opts)
  opts = opts or {}

  -- git_only: only re-run detail columns (git status, diagnostics) without
  -- rewriting buffer lines. Avoids the flicker caused by set_lines when the
  -- file tree has not changed (e.g. after a git commit/add/reset).
  if opts.git_only then
    vim.schedule(function()
      require("fyler.views.finder.ui").refresh_details(
        self.files:totable(),
        function(component, options) self.win.ui:render(component, options, opts.onrender) end
      )
    end)
    return
  end

  -- Smart file system calculation, Use cache if not `opts.update` mentioned
  local get_table = async.wrap(function(onupdate)
    if opts.force_update then
      return self.files:update(function(_, this) onupdate(this:totable()) end)
    end

    return onupdate(self.files:totable())
  end)

  async.void(function()
    local files_table = get_table()

    -- Re-check for a git repo after a filesystem update.  This handles the
    -- case where `git init` or `git clone` was run externally: the directory
    -- watcher detects the new .git/ entry and triggers a force_update, but
    -- the git watcher (start_git) was never initialised because .git didn't
    -- exist when the window was first shown.  Without this, subsequent git
    -- operations (git add, git commit, …) go undetected because the directory
    -- watcher intentionally skips .git/index changes (relying on the git
    -- watcher that was never started).
    if opts.force_update then
      self.watcher:start_git()
    end

    vim.schedule(function()
      require("fyler.views.finder.ui").files(
        files_table,
        function(component, options)
          self.win.ui:render(component, options, opts.onrender)
        end
      )
    end)
  end)
end

local function run_mutation(operations)
  local async_handler = async.wrap(function(operation, _next)
    if config.values.views.finder.delete_to_trash and operation.type == "delete" then operation.type = "trash" end

    assert(require("fyler.lib.fs")[operation.type], "Unknown operation")(operation, _next)

    return operation.path or operation.dst
  end)

  local mutation_text_format = "Mutating (%d/%d)"
  local spinner = require("fyler.lib.spinner").new(string.format(mutation_text_format, 0, #operations))
  local last_focusable_operation = nil

  spinner:start()

  for i, operation in ipairs(operations) do
    local err = async_handler(operation)
    if err then
      vim.schedule_wrap(vim.notify)(err, vim.log.levels.ERROR, { title = "Fyler" })
    else
      last_focusable_operation = (operation.path or operation.dst) or last_focusable_operation
    end

    spinner:set_text(string.format(mutation_text_format, i, #operations))
  end

  spinner:stop()

  return last_focusable_operation
end

---@return boolean
local function can_skip_confirmation(operations)
  local count = { create = 0, delete = 0, move = 0, copy = 0, chmod = 0 }

  util.tbl_each(operations, function(o) count[o.type] = (count[o.type] or 0) + 1 end)

  return count.create <= 5 and count.move <= 1 and count.copy <= 1 and count.delete <= 1
end

local get_confirmation = async.wrap(vim.schedule_wrap(function(...) require("fyler.input").confirm.open(...) end))

local function should_mutate(operations, cwd)
  if config.values.views.finder.confirm_simple and can_skip_confirmation(operations) then return true end

  return get_confirmation(require("fyler.views.finder.ui").operations(util.tbl_map(operations, function(operation)
    local result = vim.deepcopy(operation)
    if operation.type == "create" or operation.type == "delete" or operation.type == "chmod" then
      result.path = cwd:relative(operation.path) or operation.path
    else
      result.src = cwd:relative(operation.src) or operation.src
      result.dst = cwd:relative(operation.dst) or operation.dst
    end
    return result
  end)))
end

function Finder:dispatch_mutation()
  async.void(function()
    local ok, result = pcall(function() return self.files:diff_with_buffer() end)

    if not ok then
      -- diff_with_buffer raised (e.g. malformed permission string): notify and
      -- rerender the buffer so the user sees the original valid content again.
      vim.schedule_wrap(vim.notify)(tostring(result), vim.log.levels.WARN, { title = "Fyler" })
      return self:dispatch_refresh()
    end

    local operations = result

    if vim.tbl_isempty(operations) then return self:dispatch_refresh() end

    if should_mutate(operations, require("fyler.lib.path").new(self:getcwd())) then
      M.navigate(run_mutation(operations), { force_update = true })
    end
  end)
end

---Allocate the next available secondary slot (lowest recycled or next integer, max MAX_INSTANCES).
---Returns nil when the cap is already reached.
---@return integer|nil
local function next_secondary_slot()
  for slot = 2, MAX_INSTANCES do
    if not instances[slot] then return slot end
  end
  return nil
end

---Get or create the finder instance for the given slot.
---@param slot integer|nil  defaults to ORIG_SLOT
---@param dir string|nil optional directory to use when creating a new instance
---@return Finder
function M.instance(slot, dir)
  slot = slot or ORIG_SLOT
  if instances[slot] then return instances[slot] end

  -- Initialize global_cwd on first-ever instance creation
  if not global_cwd then
    global_cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
  end

  local path
  if dir then
    path = vim.fn.fnamemodify(Path.new(dir):posix_path(), ":p"):gsub("/$", "")
  else
    -- Secondaries start at the original instance's current directory
    path = (slot == ORIG_SLOT or not instances[ORIG_SLOT])
      and global_cwd
      or instances[ORIG_SLOT]:getcwd()
  end

  local uri = helper.build_protocol_uri(path, slot)

  local finder = Finder.new(uri, slot)
  finder.watcher = require("fyler.views.finder.watcher").new(finder)
  finder.files = require("fyler.views.finder.files").new({
    open = true,
    name = Path.new(path):basename(),
    path = Path.new(path):posix_path(),
    finder = finder,
  })

  instances[slot] = finder
  return finder
end

---Open a secondary instance in a split. kind must be "split_right" or "split_below".
---Respects the MAX_INSTANCES cap and recycles freed slots.
---@param kind WinKind
function M.open_secondary(kind)
  local slot = next_secondary_slot()
  if not slot then
    vim.notify("[Fyler] Maximum number of instances (" .. MAX_INSTANCES .. ") already open.", vim.log.levels.WARN)
    return
  end
  M.instance(slot):open(kind)
end

---Open a secondary instance into an existing window (replace kind).
---The caller is responsible for creating/focusing the target window first.
---@param winid integer  the window to open the secondary finder into
function M.open_secondary_in_win(winid)
  local slot = next_secondary_slot()
  if not slot then
    vim.notify("[Fyler] Maximum number of instances (" .. MAX_INSTANCES .. ") already open.", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(winid)
  M.instance(slot):open("replace")
end

---Set the global current working directory for Fyler and navigate to it
---@param path string
function M.set_current_dir(path)
  -- Normalize and validate the path (expand relative paths like "." to absolute)
  local normalized_path = vim.fn.fnamemodify(Path.new(path):posix_path(), ":p"):gsub("/$", "")
  assert(Path.new(normalized_path):is_directory(), "Path must be a valid directory")

  -- If the path hasn't changed, no need to rebuild
  if global_cwd == normalized_path then return end

  local finder = M.instance(ORIG_SLOT)
  if not finder then return end

  -- change_root handles: files rebuild, watcher restart, title/header update, global_cwd
  finder:change_root(normalized_path)

  -- Refresh the rendered tree. Works whether fyler is open or closed:
  -- if open, re-renders immediately; if closed, the stale tree is replaced next open.
  vim.schedule(function()
    finder:dispatch_refresh({ force_update = true })
  end)
end

function M.get_current_dir() return global_cwd end

---Open (or focus) a finder instance for the given directory.
---Isolated per-instance: does NOT mutate other instances' cwd.
---If an instance with that dir already exists, it is (re)opened/focused.
---Otherwise the orig slot is reused when closed, else a secondary slot is allocated.
---@param dir string directory to open
---@param kind WinKind|nil
function M.open_at(dir, kind)
  kind = kind or config.values.views.finder.win.kind
  if helper.is_protocol_uri(dir) then
    dir = helper.parse_protocol_uri(dir) or dir
  end
  local normalized = vim.fn.fnamemodify(Path.new(dir):posix_path(), ":p"):gsub("/$", "")
  assert(Path.new(normalized):is_directory(), "Path must be a valid directory")

  -- Reuse any existing instance (open or closed) that already points at this dir
  for _, inst in pairs(instances) do
    if inst:getcwd() == normalized then
      if inst:isopen() then
        -- Already open — just focus it (or reopen with different kind)
        if kind and inst.win and inst.win.kind ~= kind then
          -- Kind mismatch: close and reopen with requested kind
          inst:close()
          vim.schedule(function() inst:open(kind) end)
        end
        return inst
      else
        inst:open(kind)
        return inst
      end
    end
  end

  -- No existing instance for this dir: reuse orig if it is closed
  local orig = instances[ORIG_SLOT]
  if not orig or not orig:isopen() then
    local f = M.instance(ORIG_SLOT, normalized)
    if f:getcwd() ~= normalized then
      f:change_root(normalized)
      vim.schedule(function() f:dispatch_refresh({ force_update = true }) end)
    end
    f:open(kind)
    return f
  end

  -- Orig is open with a different dir — allocate or reuse a secondary
  local slot = next_secondary_slot()
  if slot then
    local f = M.instance(slot, normalized)
    f:open(kind)
    return f
  end
  -- No empty secondary slot: try to reuse a closed secondary
  for s = 2, MAX_INSTANCES do
    local inst = instances[s]
    if inst and not inst:isopen() then
      if inst:getcwd() ~= normalized then
        inst:change_root(normalized)
        vim.schedule(function() inst:dispatch_refresh({ force_update = true }) end)
      end
      inst:open(kind)
      return inst
    end
  end
  vim.notify("[Fyler] Maximum number of instances (" .. MAX_INSTANCES .. ") already open. Close one first.", vim.log.levels.WARN)
  return nil
end

---Toggle the finder instance for the given directory.
---If an instance with that dir is open it is closed, otherwise it is opened.
---@param dir string
---@param kind WinKind|nil
function M.toggle_at(dir, kind)
  kind = kind or config.values.views.finder.win.kind
  if helper.is_protocol_uri(dir) then
    dir = helper.parse_protocol_uri(dir) or dir
  end
  local normalized = vim.fn.fnamemodify(Path.new(dir):posix_path(), ":p"):gsub("/$", "")
  assert(Path.new(normalized):is_directory(), "Path must be a valid directory")

  for _, inst in pairs(instances) do
    if inst:getcwd() == normalized then
      if inst:isopen() then
        -- Respect kind filter if provided: only close when kind matches
        if not kind or inst:isopen(kind) then
          inst:close()
        else
          inst:open(kind)
        end
      else
        inst:open(kind)
      end
      return inst
    end
  end

  -- No existing instance for this dir — open a new one
  return M.open_at(normalized, kind)
end

---@param kind WinKind|nil
function M.open(kind) 
  M.instance(ORIG_SLOT):open(kind or config.values.views.finder.win.kind) 
end

M.close = vim.schedule_wrap(function()
  local finder = instances[ORIG_SLOT]
  if finder and finder:isopen() then
    finder:close()
  end
end)

---@param kind WinKind|nil
M.toggle = vim.schedule_wrap(function(kind)
  local finder = M.instance(ORIG_SLOT)
  if finder:isopen(kind) then
    finder:close()
  else
    finder:open(kind or config.values.views.finder.win.kind)
  end
end)

M.focus = vim.schedule_wrap(function()
  local finder = instances[ORIG_SLOT]
  if finder and finder.win then
    finder.win:focus()
  end
end)

-- TODO: Can futher optimize by determining whether `files:navgiate` did any change or not?
---@param path string|nil
M.navigate = vim.schedule_wrap(function(path, opts)
  opts = opts or {}

  local finder = instances[ORIG_SLOT]
  if not finder then return end
  
  if not finder:isopen() then return end

  local set_cursor = vim.schedule_wrap(function(ref_id)
    if finder:isopen() and ref_id then
      vim.api.nvim_win_call(finder.win.winid, function() vim.fn.search(string.format("/%05d ", ref_id)) end)
    end
  end)

  local update_table = async.wrap(function(...) finder.files:update(...) end)
  local navigate_path = async.wrap(function(...) finder:navigate(...) end)

  async.void(function()
    if opts.force_update then update_table() end

    local ref_id
    if path then
      local path = vim.fn.fnamemodify(Path.new(path):posix_path(), ":p")
      ref_id = util.select_n(2, navigate_path(path))

      if not ref_id then
        local link = manager.find_link_path_from_resolved(path)
        if link then ref_id = util.select_n(2, navigate_path(link)) end
      end
    end

    opts.onrender = function() set_cursor(ref_id) end

    finder:dispatch_refresh(opts)
  end)
end)

---Iterate all currently open Finder instances.
---@return fun(): Finder|nil
function M.iter_instances()
  local keys = vim.tbl_keys(instances)
  local i = 0
  return function()
    i = i + 1
    return instances[keys[i]]
  end
end

return M

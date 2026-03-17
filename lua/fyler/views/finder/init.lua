local Path = require("fyler.lib.path")
local async = require("fyler.lib.async")
local config = require("fyler.config")
local helper = require("fyler.views.finder.helper")
local manager = require("fyler.views.finder.files.manager")
local util = require("fyler.lib.util")

local M = {}

-- Global CWD tracking for Fyler (initialized when finder is created)
local global_cwd = nil

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

function Finder.new(uri) 
  local rwd = helper.parse_protocol_uri(uri)
  return setmetatable({ uri = uri, rwd = rwd }, Finder) 
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
        self:dispatch_refresh()
      end,
      ["BufWriteCmd"] = function()
        self:dispatch_mutation()
      end,
      [{"CursorMoved","CursorMovedI"}] = function()
        local cur = vim.api.nvim_get_current_line()
        local ref_id = helper.parse_ref_id(cur)
        if not ref_id then return end

        local _, ub = string.find(cur, ref_id)
        if not self.win:has_valid_winid() then return end

        local row, col = self.win:get_cursor()
        if not (row and col) then return end

        if col <= ub then self.win:set_cursor(row, ub + 1) end
      end,
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
      [rev_maps["CloseView"]]    = self:action "n_close",
      [rev_maps["CollapseAll"]]  = self:action "n_collapse_all",
      [rev_maps["CollapseNode"]] = self:action "n_collapse_node",
      [rev_maps["GotoCwd"]]      = self:action "n_goto_cwd",
      [rev_maps["GotoNode"]]     = self:action "n_goto_node",
      [rev_maps["GotoParent"]]   = self:action "n_goto_parent",
      [rev_maps["Select"]]       = self:action "n_select",
      [rev_maps["SelectSplit"]]  = self:action "n_select_split",
      [rev_maps["SelectTab"]]    = self:action "n_select_tab",
      [rev_maps["SelectVSplit"]] = self:action "n_select_v_split",
    },
    mappings_opts = view_cfg.mappings_opts,
    on_show       = function()
      self.watcher:enable()
      indent.attach(self.win)
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
    win_opts      = view_cfg.win.win_opts,
  }
  -- stylua: ignore end

  self.win:show()
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
  if self.win then self.win:hide() end
end

function Finder:navigate(...) self.files:navigate(...) end

-- Change `self.files` instance to provided directory path
---@param path string
function Finder:change_root(path)
  assert(path, "cannot change directory without path")
  assert(Path.new(path):is_directory(), "cannot change to non-directory path")

  self.watcher:disable(true)
  self.files = require("fyler.views.finder.files").new({
    open = true,
    name = Path.new(path):basename(),
    path = Path.new(path):posix_path(),
    finder = self,
  })

  -- Update the finder's URI to match the new path (but don't change buffer name)
  local normalized_path = vim.fn.fnamemodify(Path.new(path):posix_path(), ":p"):gsub("/$", "")
  self.uri = helper.build_protocol_uri(normalized_path)
  
  -- Update the window title
  if self.win then 
    self.win:update_title(string.format(" %s ", Path.new(path):os_path())) 
  end
  
  -- Update global CWD for display purposes (winbar, etc.)
  -- This allows external consumers like winbar to read the current navigation path
  update_global_cwd(normalized_path)

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
    vim.schedule(function()
      require("fyler.views.finder.ui").files(
        files_table,
        function(component, options) self.win.ui:render(component, options, opts.onrender) end
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
  local count = { create = 0, delete = 0, move = 0, copy = 0 }

  util.tbl_each(operations, function(o) count[o.type] = (count[o.type] or 0) + 1 end)

  return count.create <= 5 and count.move <= 1 and count.copy <= 1 and count.delete <= 1
end

local get_confirmation = async.wrap(vim.schedule_wrap(function(...) require("fyler.input").confirm.open(...) end))

local function should_mutate(operations, cwd)
  if config.values.views.finder.confirm_simple and can_skip_confirmation(operations) then return true end

  return get_confirmation(require("fyler.views.finder.ui").operations(util.tbl_map(operations, function(operation)
    local result = vim.deepcopy(operation)
    if operation.type == "create" or operation.type == "delete" then
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
    local operations = self.files:diff_with_buffer()

    if vim.tbl_isempty(operations) then return self:dispatch_refresh() end

    if should_mutate(operations, require("fyler.lib.path").new(self:getcwd())) then
      M.navigate(run_mutation(operations), { force_update = true })
    end
  end)
end

-- Single global finder instance
local current_finder = nil

---Get the global current working directory for Fyler
---@return string
function M.get_current_dir() 
  return global_cwd or vim.fn.getcwd()
end

---Set the global current working directory for Fyler and navigate to it
---@param path string
function M.set_current_dir(path)
  -- Normalize and validate the path (expand relative paths like "." to absolute)
  local normalized_path = vim.fn.fnamemodify(Path.new(path):posix_path(), ":p"):gsub("/$", "")
  assert(Path.new(normalized_path):is_directory(), "Path must be a valid directory")
  
  -- If the path hasn't changed, no need to rebuild
  if global_cwd == normalized_path then return end
  
  -- Update global CWD
  global_cwd = normalized_path
  
  -- Get the finder instance
  local finder = M.instance()
  
  -- Recreate the Files instance with the new root path
  if finder and finder.files then
    -- Stop and clean all watchers from the old files instance
    if finder.watcher then
      finder.watcher:disable(true) -- true = clean up paths
    end
    
    -- Create new Files instance
    finder.files = require("fyler.views.finder.files").new({
      open = true,
      name = Path.new(normalized_path):basename(),
      path = normalized_path,
      finder = finder,
    })
    
    -- Update the finder's URI to match the new path
    finder.uri = helper.build_protocol_uri(normalized_path)
    
    -- Update the window buffer name to match new URI
    if finder.win and finder.win.bufnr and vim.api.nvim_buf_is_valid(finder.win.bufnr) then
      vim.api.nvim_buf_set_name(finder.win.bufnr, finder.uri)
    end
    
    -- Update the window title
    if finder.win and finder.win:has_valid_winid() then
      local new_title = string.format(" %s ", Path.new(normalized_path):os_path())
      finder.win:update_title(new_title)
    end
  end
  
  -- Navigate to the new path with forced update
  vim.schedule(function()
    M.navigate(normalized_path, { force_update = true })
  end)
end

---Get or create the single global finder instance
---@return Finder
function M.instance()
  if current_finder then return current_finder end

  -- Initialize global_cwd on first instance creation if not already set
  if not global_cwd then
    global_cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
  end

  -- Use global_cwd as the initial path
  local path = global_cwd
  local uri = helper.build_protocol_uri(path)

  local finder = Finder.new(uri)
  finder.watcher = require("fyler.views.finder.watcher").new(finder)
  finder.files = require("fyler.views.finder.files").new({
    open = true,
    name = Path.new(path):basename(),
    path = Path.new(path):posix_path(),
    finder = finder,
  })

  current_finder = finder
  return current_finder
end

---@param kind WinKind|nil
function M.open(kind) 
  M.instance():open(kind or config.values.views.finder.win.kind) 
end

M.close = vim.schedule_wrap(function()
  local finder = M.instance()
  if finder and finder:isopen() then
    finder:close()
  end
end)

---@param kind WinKind|nil
M.toggle = vim.schedule_wrap(function(kind)
  local finder = M.instance()
  if finder:isopen(kind) then
    finder:close()
  else
    finder:open(kind or config.values.views.finder.win.kind)
  end
end)

M.focus = vim.schedule_wrap(function()
  local finder = M.instance()
  if finder and finder.win then
    finder.win:focus()
  end
end)

-- TODO: Can futher optimize by determining whether `files:navgiate` did any change or not?
---@param path string|nil
M.navigate = vim.schedule_wrap(function(path, opts)
  opts = opts or {}

  local finder = M.instance()
  
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

return M

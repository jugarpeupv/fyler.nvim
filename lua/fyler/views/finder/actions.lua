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
  opts = vim.tbl_extend("force", { winpick = true }, opts or {})

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

  -- Close if kind=replace|float or config.values.views.finder.close_on_select is enabled
  local should_close = self.win.kind:match("^replace")
    or self.win.kind:match("^float")
    or config.values.views.finder.close_on_select

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

    if is_usable_win(self.win.origin_win) and self.win.origin_win ~= fyler_winid then
      return self.win.origin_win
    end

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

    -- When fyler stays open and there is no other window to open the file in,
    -- create a new split beside fyler. Use nvim_open_win with a fresh buffer
    -- so the fyler buffer is never shown in the new window (avoids flicker).
    -- Explicitly size the new window so fyler retains its configured width,
    -- and account for other fixed-width windows (e.g. opencode) so they are
    -- not squished to zero by the new split.
    if not winid and not should_close then
      local new_buf = vim.api.nvim_create_buf(false, true)
      local fyler_width = fyler_win:config().width or math.floor(vim.o.columns * 0.3)
      -- Subtract the widths of other normal windows that already have
      -- winfixwidth set so that the new window does not steal their space.
      local fixed_others_width = 0
      for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if wid ~= fyler_win.winid
          and vim.api.nvim_win_is_valid(wid)
          and vim.api.nvim_win_get_config(wid).relative == ""
          and vim.wo[wid].winfixwidth then
          fixed_others_width = fixed_others_width + vim.api.nvim_win_get_width(wid) + 1
        end
      end
      local new_width = math.max(vim.o.columns - fyler_width - 1 - fixed_others_width, 1)
      winid = vim.api.nvim_open_win(new_buf, true, { split = "right", win = fyler_win.winid, width = new_width })
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
      })
    else
      -- Ensure fyler's winfixwidth is set during the split so Neovim does not
      -- touch its width while still allowing equalalways to distribute the
      -- other windows freely. Restore the original value after.
      local saved_fyler_winfixwidth = nil
      if not should_close and fyler_win and fyler_win.width and fyler_win:has_valid_winid() then
        saved_fyler_winfixwidth = vim.wo[fyler_win.winid].winfixwidth
        vim.wo[fyler_win.winid].winfixwidth = true
      end

      opener(entry.path)

      if saved_fyler_winfixwidth ~= nil and fyler_win:has_valid_winid() then
        vim.wo[fyler_win.winid].winfixwidth = saved_fyler_winfixwidth
      end
    end
  end

  if opts.winpick then
    -- For split variants, we should pick windows
    config.winpick_provider({ self.win.winid }, open_in_window, config.winpick_opts)
  else
    open_in_window()
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
      end
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
      end
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
    if self:getrwd() == self:getcwd() then return end
    
    -- Navigate within the tree (don't change tree root)
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

return M

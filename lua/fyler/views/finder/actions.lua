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
    -- create a new split immediately to the right of fyler. Use nvim_open_win
    -- with a fresh buffer so the fyler buffer is never shown in the new window
    -- (avoids flicker). Pin fyler's width temporarily so Neovim assigns all
    -- remaining space (total minus fyler minus other winfixwidth windows like
    -- opencode) to the new window without any manual arithmetic.
    if not winid and not should_close then
      local new_buf = vim.api.nvim_create_buf(false, true)
      -- Snapshot all winfixwidth window widths *before* nvim_open_win so we
      -- can restore them all after equalalways fires. Opencode stacks two
      -- windows vertically in the same screen column; deduplicate by column
      -- offset so we only count that column once toward fixed_others_width.
      local fyler_width = fyler_win:config().width or math.floor(vim.o.columns * 0.25)
      local fixed_others_width = 0
      local seen_cols = {}
      ---@type table<integer, integer>  winid -> saved width
      local fixed_win_widths = {}
      for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if wid ~= fyler_win.winid
          and vim.api.nvim_win_is_valid(wid)
          and vim.api.nvim_win_get_config(wid).relative == ""
          and vim.wo[wid].winfixwidth then
          local col = vim.api.nvim_win_get_position(wid)[2]
          local w = vim.api.nvim_win_get_width(wid)
          fixed_win_widths[wid] = w
          if not seen_cols[col] then
            seen_cols[col] = true
            fixed_others_width = fixed_others_width + w + 1
          end
        end
      end
      -- Save fyler's width too so we can restore it below.
      fixed_win_widths[fyler_win.winid] = fyler_width
      local new_width = math.max(vim.o.columns - fyler_width - 1 - fixed_others_width, 1)
      -- Create the new window. equalalways will redistribute widths after
      -- nvim_open_win returns; use vim.schedule to restore every winfixwidth
      -- window (fyler, opencode, etc.) to its saved width afterwards, then
      -- release winfixwidth on the *new* window only so future resizes work.
      winid = vim.api.nvim_open_win(new_buf, true, { split = "right", win = fyler_win.winid, width = new_width })
      local new_winid = winid
      vim.schedule(function()
        -- Restore all previously-fixed windows to their saved widths.
        for wid, w in pairs(fixed_win_widths) do
          if vim.api.nvim_win_is_valid(wid) then
            vim.api.nvim_win_set_width(wid, w)
          end
        end
        -- Set the new window to fill the remaining space.
        if vim.api.nvim_win_is_valid(new_winid) then
          vim.api.nvim_win_set_width(new_winid, new_width)
        end
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

---@param self Finder
function M.n_toggle_permission(self)
  return function()
    local perm_cfg = config.values.views.finder.columns.permission
    perm_cfg.enabled = not perm_cfg.enabled
    self:dispatch_refresh({ force_update = true })
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
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)

  local first = vim.fn.line("'<")
  local last  = vim.fn.line("'>")
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

      local cwd = self:getcwd()

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

      local get_confirmation = async.wrap(
        vim.schedule_wrap(function(...) require("fyler.input").confirm.open(...) end)
      )

      local confirmed = get_confirmation(
        require("fyler.views.finder.ui").operations(display_ops)
      )
      if not confirmed then return end

      -- Execute sequentially, same pattern as run_mutation
      local fs = require("fyler.lib.fs")
      local spinner = require("fyler.lib.spinner").new(
        string.format("Pasting (0/%d)", #operations)
      )
      spinner:start()

      local run = async.wrap(function(op, _next)
        fs[op.type](op, _next)
        return op.dst
      end)

      for i, op in ipairs(operations) do
        local err = run(op)
        if err then
          vim.schedule_wrap(vim.notify)(
            tostring(err), vim.log.levels.ERROR, { title = "Fyler" }
          )
        end
        spinner:set_text(string.format("Pasting (%d/%d)", i, #operations))
      end

      spinner:stop()

      clipboard.clear(self)
      self:dispatch_refresh({ force_update = true })

      -- Report full destination paths
      local dsts = vim.tbl_map(function(op) return op.dst end, operations)
      vim.schedule(function()
        vim.notify(
          string.format("[Fyler] Pasted %d file(s):\n%s", #dsts, table.concat(dsts, "\n")),
          vim.log.levels.INFO
        )
      end)
    end)
  end
end

return M

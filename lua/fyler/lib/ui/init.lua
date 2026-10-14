local Component = require("fyler.lib.ui.component")
local Renderer = require("fyler.lib.ui.renderer")
local Sync = require("fyler.lib.sync")

---@class Ui
---@field win Win
---@field renderer UiRenderer
---@field _lock fyler.SyncLock
---@field _generation integer  -- incremented each render request; stale renders self-abort
local Ui = {}
Ui.__index = Ui

Ui.Component = Component

---@param children UiComponent[]
Ui.Column = Ui.Component.new(function(children)
  return {
    tag = "column",
    children = children,
  }
end)

---@param children UiComponent[]
Ui.Row = Ui.Component.new(function(children)
  return {
    tag = "row",
    children = children,
  }
end)

Ui.Text = Ui.Component.new(
  function(value, option)
    return {
      tag = "text",
      value = value,
      option = option,
      children = {},
    }
  end
)

---@param win Win
---@return Ui
function Ui.new(win)
  return setmetatable({
    win = win,
    renderer = Renderer.new(),
    _lock = Sync.new_lock(),
    _generation = 0,
  }, Ui)
end

-- Whether the buffer already shows exactly `all_lines` (header included).
-- One batched read + pure-Lua compare, far cheaper than a rewrite.
---@private
---@param all_lines string[]
---@return boolean
function Ui:_same_lines(all_lines)
  if not self.win:has_valid_bufnr() then return false end
  local current = vim.api.nvim_buf_get_lines(self.win.bufnr, 0, -1, false)
  if #current ~= #all_lines then return false end
  for i = 1, #all_lines do
    if current[i] ~= all_lines[i] then return false end
  end
  return true
end

---@param component UiComponent
function Ui:render(component, ...)
  local opts = {}
  local onrender = nil

  for i = 1, select("#", ...) do
    local arg = select(i, ...)
    if type(arg) == "table" then
      opts = arg
    elseif type(arg) == "function" then
      onrender = arg
    end
  end

  -- Stamp this render request. If a newer request arrives before we start,
  -- we will find our generation stale and skip the write entirely.
  self._generation = self._generation + 1
  local my_gen = self._generation

  -- Pre-compute the renderer output synchronously (pure Lua, no API calls).
  self.renderer:render(component)
  local lines = self.renderer.line
  local highlights = self.renderer.highlight
  local extmarks = self.renderer.extmark
  local header = self.win.header
  local line_offset = (header ~= nil) and 1 or 0

  vim.schedule(function()
    -- Abort if a newer render has already been queued.
    if my_gen ~= self._generation then return end

    self._lock:acquire(function()
      -- Re-check generation inside the lock: another render may have started
      -- between the schedule and the acquire.
      if my_gen ~= self._generation then
        self._lock:release()
        return
      end

      -- Fast path: when the buffer already shows exactly these lines (e.g.
      -- plain :w with no edits), skip the entire write phase. Rewriting
      -- identical lines clears all extmarks for no benefit, flashing git
      -- icons and highlights; re-adding highlights on top would additionally
      -- stack duplicate extmarks. Identical lines mean zero pending mutation,
      -- so the buffer is explicitly unmarked modified as set_lines would do.
      -- (Pass 2 of the same cycle still refreshes extmarks with fresh data.)
      local all_lines = header and vim.list_extend({ header }, lines) or nil
      local skip_writes = all_lines ~= nil and not opts.partial and self:_same_lines(all_lines)

      if skip_writes then
        self.win:set_local_buf_option("modified", false)
      elseif not opts.partial then
        if all_lines then
          self.win:set_lines(0, -1, all_lines)
          self.win:set_extmark(0, 0, {
            end_col  = #header,
            hl_group = "NvimTreeRootFolder",
            priority = 100,
          })
        else
          self.win:set_lines(0, -1, lines)
        end
      else
        -- Partial render: keep buffer lines, only refresh extmarks.
        self.win:clear_extmarks()
        if header and self.win.bufnr and vim.api.nvim_buf_is_valid(self.win.bufnr) then
          local header_line = vim.api.nvim_buf_get_lines(self.win.bufnr, 0, 1, false)[1] or ""
          self.win:set_extmark(0, 0, {
            end_col  = #header_line,
            hl_group = "NvimTreeRootFolder",
            priority = 100,
          })
        end
      end

      if not skip_writes then
        for _, highlight in ipairs(highlights) do
          -- stylua: ignore start
          local extmark_opts = {
            end_col   = highlight.col_end,
            hl_group  = highlight.highlight_group,
            priority  = highlight.priority,
          }
          if highlight.conceal ~= nil then extmark_opts.conceal = highlight.conceal end
          self.win:set_extmark(highlight.line + line_offset, highlight.col_start, extmark_opts)
          -- stylua: ignore end
        end

        for _, extmark in ipairs(extmarks) do
          -- stylua: ignore start
          self.win:set_extmark(extmark.line + line_offset, 0, {
            hl_mode           = extmark.hl_mode,
            virt_text         = extmark.virt_text,
            virt_text_pos     = extmark.virt_text_pos,
            virt_text_win_col = extmark.virt_text_pos ~= "eol" and extmark.col or nil,
          })
          -- stylua: ignore end
        end
      end

      self._lock:release()
      pcall(onrender)
    end)
  end)
end

return Ui

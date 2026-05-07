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

      if not opts.partial then
        if header then
          local all_lines = vim.list_extend({ header }, lines)
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

      for _, highlight in ipairs(highlights) do
        -- stylua: ignore start
        self.win:set_extmark(highlight.line + line_offset, highlight.col_start, {
          end_col   = highlight.col_end,
          hl_group  = highlight.highlight_group,
          priority  = highlight.priority,
        })
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

      self._lock:release()
      pcall(onrender)
    end)
  end)
end

return Ui

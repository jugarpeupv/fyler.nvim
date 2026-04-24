local Component = require("fyler.lib.ui.component")
local Renderer = require("fyler.lib.ui.renderer")

---@class Ui
---@field win Win
---@field renderer UiRenderer
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
function Ui.new(win) return setmetatable({ win = win, renderer = Renderer.new() }, Ui) end

---@param component UiComponent
Ui.render = vim.schedule_wrap(function(self, component, ...)
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

  -- Render Ui components to neovim api compatible
  self.renderer:render(component)

  -- When the window has a header line (line 0), the renderer output occupies
  -- lines 1..N. Shift all line indices reported by the renderer by +1 so
  -- extmarks land on the correct rows after the header is written.
  local line_offset = (self.win.header ~= nil) and 1 or 0

  if not opts.partial then
    if self.win.header then
      -- Write the header at row 0, then file lines at rows 1..N.
      -- Use a single set_lines call that prepends the header so the
      -- on_lines extmark-shift logic sees one atomic write.
      local all_lines = vim.list_extend({ self.win.header }, self.renderer.line)
      self.win:set_lines(0, -1, all_lines)
      -- Highlight the header line as a directory path
      self.win:set_extmark(0, 0, {
        end_col  = #self.win.header,
        hl_group = "NvimTreeRootFolder",
        priority = 100,
      })
    else
      self.win:set_lines(0, -1, self.renderer.line)
    end
  else
    -- Partial render: keep buffer lines, only refresh extmarks
    self.win:clear_extmarks()
    -- Re-apply header highlight after clearing extmarks
    if self.win.header then
      self.win:set_extmark(0, 0, {
        end_col  = #self.win.header,
        hl_group = "NvimTreeRootFolder",
        priority = 100,
      })
    end
  end

  for _, highlight in ipairs(self.renderer.highlight) do
    -- stylua: ignore start
    self.win:set_extmark(highlight.line + line_offset, highlight.col_start, {
      end_col   = highlight.col_end,
      hl_group  = highlight.highlight_group,
      priority  = highlight.priority,
    })
    -- stylua: ignore end
  end

  for _, extmark in ipairs(self.renderer.extmark) do
    -- stylua: ignore start
    self.win:set_extmark(extmark.line + line_offset, 0, {
      hl_mode           = extmark.hl_mode,
      virt_text         = extmark.virt_text,
      virt_text_pos     = extmark.virt_text_pos,
      virt_text_win_col = extmark.virt_text_pos ~= "eol" and extmark.col or nil,
    })
    -- stylua: ignore end
  end

  pcall(onrender)
end)

return Ui

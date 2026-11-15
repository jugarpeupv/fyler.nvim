--- INTRODUCTION
---
--- Fyler.nvim is a Neovim file manager plugin based on buffer-based file editing.
---
--- Why choose Fyler.nvim over |oil.nvim|?
--- - Provides a tree view.
--- - Users can have a full overview of their project without going back and forth
---   between directories.
---
--- GETTING STARTED
---
--- 1. Fyler must be setup correctly before use.
---
--- USAGE
---
--- Fyler can be used through commands or the Lua API.
---
--- COMMANDS
---
--- :Fyler dir=... kind=...
---
--- Parameters:
--- dir    Path to the directory to open
--- kind   Display method, one of:
---        - `float`
---        - `replace`
---        - `split_above`
---        - `split_above_all`
---        - `split_below`
---        - `split_below_all`
---        - `split_left`
---        - `split_left_most`
---        - `split_right`
---        - `split_right_most`
---
--- LUA API
---
--- >lua
---     local fyler = require("fyler")
---
---     -- Opens finder view with given options
---     fyler.open({ dir = "...", kind = "..." })
---
---     -- Toggles finder view with given options
---     fyler.toggle({ dir = "...", kind = "..." })
---
---     -- Focuses finder view
---     fyler.focus()
---
---     -- Focuses given file path or alternate buffer
---     fyler.navigate("...")
---
--- SESSIONS
---
--- Fyler integrates with |:mksession|: loading a session reopens every fyler
--- view in the window where it was saved, with the same directory and
--- instance slot. This requires the `blank` flag in 'sessionoptions' (present
--- in Neovim's default) so that the window is stored in the session. The cursor
--- position is restored too (re-expanding the path to the entry when needed);
--- floating views and the rest of the expanded tree state are not persisted,
--- since sessions cannot serialize plugin state. Do not wipe fyler buffers
--- before saving the session (some session managers wipe special buffers in a
--- pre-save hook): the empty placeholder written by |:mksession| is what allows
--- the view to be restored.
--- <
---
---@tag fyler.nvim

local M = {}

local did_setup = false

---@param opts FylerSetup|nil
function M.setup(opts)
  if vim.fn.has("nvim-0.11") == 0 then return vim.notify("Fyler requires at least NVIM 0.11") end

  if did_setup then return end

  require("fyler.config").setup(opts)

  did_setup = true

  -- A session may have been loaded before this plugin (lazy loading): rebuild
  -- any fyler placeholder it left behind.
  vim.schedule(function() require("fyler.session").restore() end)

  local finder = setmetatable({}, { __index = function(_, k) return require("fyler.views.finder")[k] end })

  -- Fyler.API: Opens finder view with provided options
  -- When `dir` is provided, isolates per-instance: existing fyler buffers keep
  -- their cwd, new instance is opened for the requested dir.
  M.open = function(args)
    args = args or {}
    if args.dir then
      if finder.open_at then
        finder.open_at(args.dir, args.kind)
      else
        finder.set_current_dir(args.dir)
        finder.open(args.kind)
      end
    else
      finder.open(args.kind)
    end
  end

  -- Fyler.API: Closes current finder view
  M.close = finder.close

  -- Fyler.API: Toggles finder view with provided options
  M.toggle = function(args)
    args = args or {}
    if args.dir then
      if finder.toggle_at then
        finder.toggle_at(args.dir, args.kind)
      else
        finder.set_current_dir(args.dir)
        finder.toggle(args.kind)
      end
    else
      finder.toggle(args.kind)
    end
  end

  -- Fyler.API: Focus finder view
  M.focus = finder.focus

  -- Fyler.API: Focuses given file path
  M.navigate = function(path) finder.navigate(path) end

  -- Fyler.API: Set global current working directory
  M.set_current_dir = finder.set_current_dir

  -- Fyler.API: Get global current working directory
  M.get_current_dir = finder.get_current_dir
end

return M

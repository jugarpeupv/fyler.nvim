local Path = require("fyler.lib.path")

local M = {}

function M.dump(opts, _next)
  local abspath = Path.new(opts.path):os_path()

  local async = require("fyler.lib.async")
  local get_confirmation = async.wrap(
    vim.schedule_wrap(function(...) require("fyler.input").confirm.open(...) end)
  )

  -- Ask "permanently delete instead?" with the given reason lines.
  -- "y" deletes permanently; "n" reports success silently so the file
  -- stays on disk and the view refresh restores its line (true cancel).
  local function ask_permanent(reason_lines)
    local message = {}
    vim.list_extend(message, reason_lines)
    table.insert(message, "  Permanently delete instead?  ")
    table.insert(message, "  " .. abspath .. "  ")
    -- NOTE: async.void executes immediately and returns nothing,
    -- so it must NOT be called with a trailing ().
    async.void(function()
      local confirmed = get_confirmation(message)
      if confirmed then
        require("fyler.lib.fs").delete({ path = opts.path }, _next)
      else
        pcall(_next)
      end
    end)
  end

  -- /usr/bin/trash only exists on macOS 15+. Without it there is no
  -- trash to fall back from, so ask directly instead of asserting.
  if vim.fn.executable("/usr/bin/trash") ~= 1 then
    ask_permanent({ "  Trash is not available on this system.  " })
    return
  end

  local Process = require("fyler.lib.process")
  local proc = Process.new({
    path = "/usr/bin/trash",
    args = { abspath },
  })

  proc:spawn_async(function(code)
    vim.schedule(function()
      if code == 0 then
        pcall(_next)
      else
        local stderr = proc:err() or ""

        -- The file can already be gone when trash runs (e.g. a previous
        -- :w already trashed it). /usr/bin/trash then fails with
        -- fnfErr/Code=4 "doesn't exist" — that is NOT an unsupported
        -- volume, so treat it as success and let the view refresh.
        if stderr:find("doesn%'t exist") or stderr:find("fnfErr") or stderr:find("File not found") then
          pcall(_next)
          return
        end

        -- Extract the volume name from the macOS error string, e.g.:
        --   "the volume "pCloud Drive" doesn't have one."
        local volume = stderr:match('volume "([^"]+)"') or "this volume"

        local lines = {
          string.format('  Trash is not supported on "%s".  ', volume),
        }
        -- Include the real stderr so the actual reason is diagnosable.
        stderr = stderr:gsub("%s+$", "")
        if stderr ~= "" then table.insert(lines, "  " .. stderr .. "  ") end

        ask_permanent(lines)
      end
    end)
  end)
end

return M

local Path = require("fyler.lib.path")

local M = {}

function M.dump(opts, _next)
  local abspath = Path.new(opts.path):os_path()
  local Process = require("fyler.lib.process")
  local proc

  -- Built-in trash command available on macOS 15 and later
  proc = Process.new({
    path = "/usr/bin/trash",
    args = { abspath },
  })

  proc:spawn_async(function(code)
    vim.schedule(function()
      if code == 0 then
        pcall(_next)
      else
        local stderr = proc:err() or ""

        -- Extract the volume name from the macOS error string, e.g.:
        --   "the volume "pCloud Drive" doesn't have one."
        local volume = stderr:match('volume "([^"]+)"') or "this volume"

        local message = {
          string.format('  Trash is not supported on "%s".  ', volume),
          "  Permanently delete instead?  ",
          "  " .. abspath .. "  ",
        }

        local async = require("fyler.lib.async")
        local get_confirmation = async.wrap(
          vim.schedule_wrap(function(...) require("fyler.input").confirm.open(...) end)
        )

        async.void(function()
          local confirmed = get_confirmation(message)
          if confirmed then
            require("fyler.lib.fs").delete({ path = opts.path }, _next)
          else
            pcall(_next)
          end
        end)()
      end
    end)
  end)
end

return M

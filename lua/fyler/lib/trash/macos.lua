local Path = require("fyler.lib.path")

local M = {}

function M.dump(opts, _next)
  local abspath = Path.new(opts.path):os_path()

  -- Permanently delete without asking again: the delete operation itself
  -- was already confirmed, so a missing/failing trash backend must not
  -- produce a second confirmation dialog.
  local function delete_permanently()
    require("fyler.lib.fs").delete({ path = opts.path }, _next)
  end

  -- /usr/bin/trash only exists on macOS 15+. Without it there is no
  -- trash to fall back from, so delete directly instead of asserting.
  if vim.fn.executable("/usr/bin/trash") ~= 1 then
    delete_permanently()
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

        delete_permanently()
      end
    end)
  end)
end

return M

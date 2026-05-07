-- SyncLock: serialises async render calls so that:
--   * only one render runs at a time (no concurrent set_lines races)
--   * if a second render arrives while one is in-flight, it replaces any
--     already-queued (but not yet started) render — so fast repeat refreshes
--     collapse into a single trailing render instead of piling up.
--
-- Ported from upstream refactor/quality-of-life branch.

---@class fyler.SyncLock
local Lock = {}
Lock.__index = Lock

---@param process function
function Lock:acquire(process)
  if self._locked then
    -- Replace any pending queued render with the latest one.
    self._queued = process
    return
  end

  self._locked = true
  self._queued = nil

  local ok, err = pcall(process)
  if not ok then
    vim.schedule(function()
      vim.notify("fyler render error: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

function Lock:release()
  self._locked = false

  if self._queued then
    local next = self._queued
    self._queued = nil
    self:acquire(next)
  end
end

local M = {}

---@return fyler.SyncLock
function M.new_lock()
  local instance = { _locked = false, _queued = nil }
  setmetatable(instance, Lock)
  return instance
end

return M

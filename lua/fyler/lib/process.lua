---@class ProcessOpts
---@field path string
---@field args string[]|nil
---@field stdin string|nil

---@class Process
---@field pid integer
---@field handle uv.uv_process_t
---@field path string
---@field args string[]|nil
---@field stdin string|nil
---@field stdout string|nil
---@field stderr string|nil
local Process = {}
Process.__index = Process

---@param options ProcessOpts
---@return Process
function Process.new(options)
  local instance = {
    path = options.path,
    args = options.args,
    stdin = options.stdin,
    stdio = {},
  }

  setmetatable(instance, Process)

  return instance
end

---@return Process
function Process:spawn()
  local out = vim.system(vim.list_extend({ self.path }, self.args), { text = true, stdin = self.stdin }):wait()
  self.code = out.code
  self.signal = out.signal
  self.stdout = out.stdout
  self.stderr = out.stderr

  return self
end

function Process:spawn_async(on_exit)
  assert(vim.fn.executable(self.path) == 1, string.format("executable not found: %s", self.path))

  local cmd = vim.list_extend({ self.path }, self.args or {})

  -- Use vim.system with a callback for async execution.  Unlike the previous
  -- manual uv.spawn + uv.write approach, vim.system handles stdin of any size
  -- correctly (the single uv.write would silently truncate stdin larger than
  -- the OS pipe buffer, ~64 KB, causing git check-ignore to receive no input
  -- and exit 1 when the visible file list is large).
  vim.system(cmd, { text = true, stdin = self.stdin or "" }, function(out)
    self.code   = out.code
    self.signal = out.signal
    self.stdout = out.stdout
    self.stderr = out.stderr
    -- vim.system callbacks already run in a scheduled context safe for vim.api.*
    vim.schedule(function() on_exit(out.code) end)
  end)
end

---@return boolean
function Process:is_running() return vim.uv.is_active(self.handle) == true end

---@return string
function Process:out() return self.stdout end

---@return string
function Process:err() return self.stderr end

function Process:stdout_iter()
  if not self.stdout then
    return function() end
  end

  local lines = vim.split(self.stdout, "\n")
  local i = 0
  return function()
    i = i + 1
    if i <= #lines then return i, lines[i] end
  end
end

function Process:stderr_iter()
  if not self.stderr then return end

  local lines = vim.split(self.stderr, "\n")
  local i = 0
  return function()
    i = i + 1
    if i <= #lines then return i, lines[i] end
  end
end

return Process

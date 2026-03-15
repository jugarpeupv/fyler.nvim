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

  local options = {
    args = self.args,
    stdio = {
      vim.uv.new_pipe(false),
      vim.uv.new_pipe(false),
      vim.uv.new_pipe(false),
    },
  }

  -- Delay calling on_exit until stdout is fully drained.  The libuv process
  -- exit callback fires as soon as the process dies, but the read_start
  -- callbacks for stdout/stderr may still have buffered chunks queued.
  -- Calling on_exit before those chunks are delivered means stdout_iter()
  -- sees an incomplete (or empty) buffer.
  --
  -- Strategy: latch the exit code when the process exits, then fire on_exit
  -- from the stdout EOF handler (data == nil) once all data has been read.
  local exit_code = nil
  local stdout_done = false

  local function maybe_finish()
    if exit_code ~= nil and stdout_done then
      -- Schedule on the main loop: libuv callbacks (spawn exit and read_start)
      -- run in a fast-event context where vim.api.* calls are forbidden.
      -- vim.schedule ensures on_exit (and everything it calls) runs safely.
      vim.schedule(function() on_exit(exit_code) end)
    end
  end

  self.handle, self.pid = vim.uv.spawn(self.path, options, function(code)
    exit_code = code
    maybe_finish()
  end)

  vim.uv.write(options.stdio[1], self.stdin or "", function() vim.uv.close(options.stdio[1]) end)

  vim.uv.read_start(options.stdio[2], function(_, data)
    self.stdout = self.stdout or ""
    if data then
      self.stdout = self.stdout .. data
    else
      vim.uv.read_stop(options.stdio[2])
      vim.uv.close(options.stdio[2])
      stdout_done = true
      maybe_finish()
    end
  end)

  vim.uv.read_start(options.stdio[3], function(_, data)
    self.stderr = self.stderr or ""
    if data then
      self.stderr = self.stderr .. data
    else
      vim.uv.read_stop(options.stdio[3])
      vim.uv.close(options.stdio[3])
    end
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

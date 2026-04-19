local M = {}

M.PREFIX = "fyler://"

---Serialise paths and action into the + (system) clipboard register.
---@param finder Finder
function M.flush(finder)
  if not finder.clipboard or vim.tbl_isempty(finder.clipboard.paths) then
    vim.fn.setreg("+", "")
    return
  end

  local paths = vim.tbl_keys(finder.clipboard.paths)
  table.sort(paths)

  local payload = vim.json.encode({ action = finder.clipboard.action, paths = paths })
  vim.fn.setreg("+", M.PREFIX .. payload)
end

---Read the system clipboard and decode a fyler payload.
---Returns nil when the clipboard does not contain fyler-formatted content.
---@return { action: "copy"|"move", paths: string[] }|nil
function M.read()
  local reg = vim.fn.getreg("+")
  if type(reg) ~= "string" or not vim.startswith(reg, M.PREFIX) then return nil end

  local json = reg:sub(#M.PREFIX + 1)
  local ok, payload = pcall(vim.json.decode, json)
  if not ok or type(payload) ~= "table" then return nil end
  if payload.action ~= "copy" and payload.action ~= "move" then return nil end
  if type(payload.paths) ~= "table" or #payload.paths == 0 then return nil end

  return payload
end

---Reset clipboard state and wipe the system clipboard register.
---@param finder Finder
function M.clear(finder)
  if not finder.clipboard then return end
  finder.clipboard = { action = nil, paths = {} }
  vim.fn.setreg("+", "")
end

return M


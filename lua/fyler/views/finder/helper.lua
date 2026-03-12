local M = {}

---@param uri string|nil
---@return boolean
function M.is_protocol_uri(uri) return uri and (not not uri:match("^fyler://")) or false end

---@param dir string
---@return string
function M.build_protocol_uri(dir) return string.format("fyler://%s", dir) end

---@param uri string|nil
---@return string
function M.normalize_uri(uri)
  local dir = nil
  if not uri or uri == "" then
    dir = vim.fn.getcwd()
  elseif M.is_protocol_uri(uri) then
    dir = M.parse_protocol_uri(uri)
    dir = dir or vim.fn.getcwd()
  else
    dir = uri
  end
  return M.build_protocol_uri(require("fyler.lib.path").new(dir):posix_path())
end

---@param uri string
---@return string|nil
function M.parse_protocol_uri(uri)
  if M.is_protocol_uri(uri) then return string.match(uri, "^fyler://(.*)$") end
end

---@param str string
---@return integer|nil
function M.parse_ref_id(str) return tonumber(str:match("/(%d+)")) end

---@param str string
---@return integer
function M.parse_indent_level(str) return #(str:match("^(%s*)" or "")) end

---@param str string
---@return string
function M.parse_name(str)
  if M.parse_ref_id(str) then
    return str:match("/%d+ (.*)$")
  else
    return str:gsub("^%s*", ""):match(".*")
  end
end

return M

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

---Returns the 9-char permission string embedded in a buffer line, or nil when
---the permission column is not present in that line.
---Lines with a ref_id have format: <indent><icon>  /NNNNN name  rwxrwxrwx
---                                                              ^^^^^^^^^^^
---@param str string
---@return string|nil
function M.parse_permissions(str)
  -- Permissions are the last 9 non-space characters on the line.
  local after_ref = str:match("/%d+ (.*)$")
  if not after_ref then return nil end
  local perm = after_ref:match("%s+([rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-])%s*$")
  return perm or nil
end

---Returns true when the name portion of a buffer line ends with "/", indicating
---the user intends this entry to be a directory (used for new entries).
---@param str string
---@return boolean
function M.parse_is_directory(str)
  local name
  if M.parse_ref_id(str) then
    local after_ref = str:match("/%d+ (.*)$")
    if not after_ref then return false end
    -- Strip trailing permissions ("  rwxrwxrwx") if present, then check for "/"
    name = after_ref:gsub("%s+[rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-]%s*$", "")
  else
    name = str:gsub("^%s*", "")
  end
  return name:sub(-1) == "/"
end

---@param str string
---@return string
function M.parse_name(str)
  local name
  if M.parse_ref_id(str) then
    local after_ref = str:match("/%d+ (.*)$")
    if not after_ref then return "" end
    -- Strip trailing permissions ("  rwxrwxrwx") if present
    name = after_ref:gsub("%s+[rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-]%s*$", "")
  else
    name = str:gsub("^%s*", ""):match(".*")
  end
  -- Strip trailing "/" added for directory display
  return (name:gsub("/$", ""))
end

return M

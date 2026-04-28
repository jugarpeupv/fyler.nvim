local M = {}

local ORIG_SLOT = 1

---@param uri string|nil
---@return boolean
function M.is_protocol_uri(uri) return uri and (not not uri:match("^fyler://")) or false end

---Build a fyler:// URI that encodes the directory path and the instance slot.
---  slot 1 (original): fyler:///abs/path/__orig__/1
---  slot N (secondary): fyler:///abs/path/__slot__/N
---@param dir string
---@param slot integer|nil  defaults to 1 (original)
---@return string
function M.build_protocol_uri(dir, slot)
  slot = slot or ORIG_SLOT
  local suffix = (slot == ORIG_SLOT)
    and string.format("/__orig__/%d", slot)
    or  string.format("/__slot__/%d", slot)
  return string.format("fyler://%s%s", dir, suffix)
end

---Parse a fyler:// URI and return the directory path and slot number.
---@param uri string
---@return string|nil path, integer slot
function M.parse_protocol_uri(uri)
  if not M.is_protocol_uri(uri) then return nil, ORIG_SLOT end
  local raw = uri:match("^fyler://(.*)$")
  if not raw then return nil, ORIG_SLOT end

  -- New slot-aware format
  local path, slot_str = raw:match("^(.-)/__orig__/(%d+)$")
  if path then return path, ORIG_SLOT end

  path, slot_str = raw:match("^(.-)/__slot__/(%d+)$")
  if path then return path, tonumber(slot_str) end

  -- Legacy format (no slot suffix) — treat as original
  return raw, ORIG_SLOT
end

---@param uri string|nil
---@return string
function M.normalize_uri(uri)
  local dir = nil
  if not uri or uri == "" then
    dir = vim.fn.getcwd()
  elseif M.is_protocol_uri(uri) then
    local path = M.parse_protocol_uri(uri)
    dir = path or vim.fn.getcwd()
  else
    dir = uri
  end
  return M.build_protocol_uri(require("fyler.lib.path").new(dir):posix_path(), ORIG_SLOT)
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

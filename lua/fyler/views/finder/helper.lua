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

-- Pattern for a 9-char permission string: exactly [rwx-]{9}
local PERM_PATTERN = "^[rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-]$"

---Returns the 9-char permission string embedded in a buffer line, or nil when
---the permission column is not present in that line.
---Lines with a ref_id have format: <indent><icon>  /NNNNN rwxrwxrwx name
---                                                        ^^^^^^^^^^^
---@param str string
---@return string|nil
function M.parse_permissions(str)
  -- After the ref_id token there may be a 9-char permission string followed by a space.
  local after_ref = str:match("/%d+ (.*)$")
  if not after_ref then return nil end
  local perm = after_ref:sub(1, 9)
  -- The 10th character must be a space to confirm the permission block is
  -- properly delimited from the filename (guards against "rw-r--r--filename").
  if perm:match(PERM_PATTERN) and after_ref:sub(10, 10) == " " then return perm end
  return nil
end

---Returns true when the name portion of a buffer line ends with "/", indicating
---the user intends this entry to be a directory (used for new entries).
---@param str string
---@return boolean
function M.parse_is_directory(str)
  -- For lines with a ref_id the type is already known from the trie; we only
  -- need this for new (ref_id-less) entries.  Still, handle both cases the same
  -- way: strip the perm prefix if present, then check for trailing "/".
  local name
  if M.parse_ref_id(str) then
    local after_ref = str:match("/%d+ (.*)$")
    if not after_ref then return false end
    local perm = after_ref:sub(1, 9)
    if perm:match(PERM_PATTERN) and after_ref:sub(10, 10) == " " then
      name = after_ref:sub(11)
    else
      name = after_ref
    end
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
    -- If a permission prefix is present, skip it (9 chars + 1 space = 10 chars)
    local perm = after_ref:sub(1, 9)
    if perm:match(PERM_PATTERN) and after_ref:sub(10, 10) == " " then
      name = after_ref:sub(11)
    else
      name = after_ref
    end
  else
    name = str:gsub("^%s*", ""):match(".*")
  end
  -- Strip trailing "/" added for directory display
  return (name:gsub("/$", ""))
end

return M

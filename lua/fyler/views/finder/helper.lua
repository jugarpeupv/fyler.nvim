local config = require("fyler.config")

local M = {}

local ORIG_SLOT = 1

local function col_enabled(name)
  local values = config.values
  local cols = values and values.views and values.views.finder and values.views.finder.columns
  return (cols and cols[name] and cols[name].enabled) and true or false
end

local PERM_CLASS = "[rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-]"
-- ls-style file-type prefix, as rendered by get_permissions (".rw-r--r--",
-- "drwxr-xr-x", "lrwxrwxrwx", ...). Optional when matching so a deleted
-- prefix still parses; the type character itself is read-only and never
-- produces an action — only the last 9 rwx characters are returned.
local PERM_TYPE_CLASS = "[%.dlcbps?-]"

---Split "<name>  <perms>  <rest>" (ref_id lines) into name and perms.
---Render puts the metadata after the filename:
---  /NNNNN name[  .rwxrwxrwx][ | size][ | DD/MM/YY HH:MM]
---so the perm block is the LAST 9-char [rwx-] run (with its optional
---ls-style type prefix) preceded by two spaces (greedy name match).
---Anything after it — the trailing size/date text or tampered junk — is
---ignored, never validated: size edits are always no-ops. The returned
---perms are always the last 9 rwx characters; an edited type prefix is a
---silent no-op, never an action.
---Returns name, perms|nil. When the permission column is disabled the whole
---remainder is the name and perms is nil.
---@param after_date string text after the "/NNNNN " token (date/size already stripped)
---@return string, string|nil
local function split_name_perms(after_date)
  local name, perm = after_date:match("^(.*)  (" .. PERM_TYPE_CLASS .. "?" .. PERM_CLASS .. ")(%s.*)$")
  if name then return name, perm:sub(-9) end
  local n2, p2 = after_date:match("^(.*)  (" .. PERM_TYPE_CLASS .. "?" .. PERM_CLASS .. ")$")
  if n2 then return n2, p2:sub(-9) end
  return after_date, nil
end

local DATE_PAT = "%d%d/%d%d/%d%d %d%d:%d%d"
local SIZE_PAT = "[%d.]+[BKMGT]"

---Parse "/NNNNN name[  perms][ | size][ | date]" (each metadata field present
---per its column flag) into name, perms. The size region is never
---interpreted: a single trailing size block is stripped and anything else
---after the perm block is ignored, so size edits are silent no-ops. The date
---trails at the end of the line and is located by pattern (DD/MM/YY HH:MM);
---it cannot collide with a filename because names never contain "/".
---@param line string full buffer line (must carry a ref_id)
---@return string|nil name, string|nil perms, string|nil err
---err is non-nil when the line is structurally invalid (missing trailing
---date while the date column is on). A missing perm block is NOT an error
---here — the resolver validates it separately so the message can name the
---field.
function M.parse_entry(line)
  local after_ref = line:match("/%d%d%d%d%d+%s?(.*)$")
  if not after_ref then return nil, nil, "expected entry text after the id" end
  local rest = after_ref
  if col_enabled("creation_time") then
    local before = rest:match("^(.*)%s+|%s*" .. DATE_PAT .. "%s*$") or rest:match("^(.*)%s%s+" .. DATE_PAT .. "%s*$")
    if not before then return nil, nil, "expected '<DD/MM/YY HH:MM>' date at the end of the entry" end
    rest = before:gsub("%s+$", "")
    if rest == "" then return nil, nil, "expected file name before the date" end
  end
  if col_enabled("size") then
    local no_size = rest:match("^(.*)%s+|%s*" .. SIZE_PAT .. "%s*$") or rest:match("^(.*)%s%s+" .. SIZE_PAT .. "%s*$")
    if no_size then
      rest = no_size:gsub("%s+$", "")
      if rest == "" then return nil, nil, "expected file name" end
    end
  end
  if col_enabled("permission") then
    local name, perm = split_name_perms(rest)
    return name, perm, nil
  end
  return rest, nil, nil
end

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
  local suffix = (slot == ORIG_SLOT) and string.format("/__orig__/%d", slot) or string.format("/__slot__/%d", slot)
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
-- The id token is always "/NNNNN" (5+ digits, usually followed by whitespace).
-- The strict shape keeps date-like text ("04/10/26 ...") in user-typed lines
-- from parsing as an id. The trailing space is optional so a line ending in
-- a bare id still resolves (and then fails entry validation) instead of
-- being mistaken for a new entry.
function M.parse_ref_id(str) return tonumber(str:match("/(%d%d%d%d%d+)%s?")) end

---@param str string
---@return integer
function M.parse_indent_level(str) return #(str:match("^(%s*)" or "")) end

---Returns the 9-char rwx permission string embedded in a buffer line, or nil
---when the permission column is not present in that line (or the line is
---invalid). Rendered lines carry an ls-style 10-char block (".rw-r--r--",
---"drwxr-xr-x"); the type prefix is dropped, only the last 9 characters
---are returned.
---Lines with a ref_id have format: <indent><icon>  /NNNNN name[  perms][ | size][ | date]
---@param str string
---@return string|nil
function M.parse_permissions(str)
  if not M.parse_ref_id(str) then return nil end
  local _, perm = M.parse_entry(str)
  return perm
end

---Returns true when the name portion of a buffer line ends with "/", indicating
---the user intends this entry to be a directory (used for new entries).
---@param str string
---@return boolean
function M.parse_is_directory(str)
  if not M.parse_ref_id(str) then return str:gsub("^%s*", ""):sub(-1) == "/" end
  local name = M.parse_entry(str)
  if not name then return false end
  return name:sub(-1) == "/"
end

---@param str string
---@return string
function M.parse_name(str)
  local name
  if not M.parse_ref_id(str) then
    name = str:gsub("^%s*", ""):match(".*")
  else
    name = M.parse_entry(str) or ""
  end
  -- Strip trailing "/" added for directory display
  return (name:gsub("/$", ""))
end

return M

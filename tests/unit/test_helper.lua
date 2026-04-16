-- Unit tests for lua/fyler/views/finder/helper.lua
-- Focused on parse_permissions (space-check guard) and parse_is_directory.

local helper_mod = require("fyler.views.finder.helper")
local MiniTest = require("mini.test")

local T = MiniTest.new_set()
local equal = MiniTest.expect.equality

-- ---------------------------------------------------------------------------
-- parse_permissions
-- ---------------------------------------------------------------------------

T["parse_permissions"] = MiniTest.new_set()

T["parse_permissions"]["returns perm string for valid line"] = function()
  -- Typical buffer line with a 9-char perm block followed by a space
  local line = "  icon  /00001 rw-r--r-- my-file"
  equal(helper_mod.parse_permissions(line), "rw-r--r--")
end

T["parse_permissions"]["returns nil when 10th char is not space"] = function()
  -- 9 valid chars but immediately followed by a letter (filename runs into perm)
  local line = "  icon  /00001 rw-r--r--my-file"
  equal(helper_mod.parse_permissions(line), nil)
end

T["parse_permissions"]["returns nil when perm chars are invalid"] = function()
  -- Contains 'z' which is not [rwx-]
  local line = "  icon  /00001 rw-r--r-z my-file"
  equal(helper_mod.parse_permissions(line), nil)
end

T["parse_permissions"]["returns nil when no ref_id present"] = function()
  -- New entry (no /NNNNN token)
  local line = "  rw-r--r-- my-new-file"
  equal(helper_mod.parse_permissions(line), nil)
end

T["parse_permissions"]["returns nil for empty line"] = function()
  equal(helper_mod.parse_permissions(""), nil)
end

T["parse_permissions"]["returns perm string of all dashes"] = function()
  local line = "  icon  /00002 --------- some-file"
  equal(helper_mod.parse_permissions(line), "---------")
end

T["parse_permissions"]["returns perm string of all rwx"] = function()
  local line = "  icon  /00003 rwxrwxrwx exec-file"
  equal(helper_mod.parse_permissions(line), "rwxrwxrwx")
end

T["parse_permissions"]["returns nil when perm block is only 8 chars"] = function()
  -- Only 8 permission characters (too short), no trailing space at position 10
  local line = "  icon  /00004 rw-r--r- my-file"
  equal(helper_mod.parse_permissions(line), nil)
end

-- ---------------------------------------------------------------------------
-- parse_is_directory
-- ---------------------------------------------------------------------------

T["parse_is_directory"] = MiniTest.new_set()

T["parse_is_directory"]["returns true for new entry with trailing slash"] = function()
  local line = "  new-dir/"
  equal(helper_mod.parse_is_directory(line), true)
end

T["parse_is_directory"]["returns false for new entry without trailing slash"] = function()
  local line = "  new-file"
  equal(helper_mod.parse_is_directory(line), false)
end

T["parse_is_directory"]["returns true for ref_id entry with perm and trailing slash"] = function()
  local line = "  icon  /00010 rwxr-xr-x apps/"
  equal(helper_mod.parse_is_directory(line), true)
end

T["parse_is_directory"]["returns false for ref_id entry with perm and no trailing slash"] = function()
  local line = "  icon  /00011 rw-r--r-- readme.md"
  equal(helper_mod.parse_is_directory(line), false)
end

T["parse_is_directory"]["returns true for ref_id entry without perm and trailing slash"] = function()
  -- Permission column disabled: no perm block
  local line = "  icon  /00012 my-dir/"
  equal(helper_mod.parse_is_directory(line), true)
end

T["parse_is_directory"]["returns false for ref_id entry without perm and no trailing slash"] = function()
  local line = "  icon  /00013 my-file"
  equal(helper_mod.parse_is_directory(line), false)
end

T["parse_is_directory"]["returns false for empty line"] = function()
  equal(helper_mod.parse_is_directory(""), false)
end

-- ---------------------------------------------------------------------------
-- parse_name (regression checks related to trailing-slash stripping)
-- ---------------------------------------------------------------------------

T["parse_name"] = MiniTest.new_set()

T["parse_name"]["strips trailing slash from directory name"] = function()
  local line = "  icon  /00020 rwxr-xr-x apps/"
  equal(helper_mod.parse_name(line), "apps")
end

T["parse_name"]["preserves filename without trailing slash"] = function()
  local line = "  icon  /00021 rw-r--r-- file.txt"
  equal(helper_mod.parse_name(line), "file.txt")
end

T["parse_name"]["works without perm block (perm column disabled)"] = function()
  local line = "  icon  /00022 plain-name"
  equal(helper_mod.parse_name(line), "plain-name")
end

T["parse_name"]["strips trailing slash when perm column disabled"] = function()
  local line = "  icon  /00023 plain-dir/"
  equal(helper_mod.parse_name(line), "plain-dir")
end

T["parse_name"]["returns name for new entry (no ref_id)"] = function()
  local line = "  new-file.txt"
  equal(helper_mod.parse_name(line), "new-file.txt")
end

return T

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
  -- Real render order: /NNNNN name, then the 9-char perm block
  local line = "  icon  /00001 my-file  rw-r--r--"
  equal(helper_mod.parse_permissions(line), "rw-r--r--")
end

T["parse_permissions"]["returns nil when perm is glued to trailing text"] = function()
  -- 9 valid chars but immediately followed by a letter instead of whitespace
  local line = "  icon  /00001 my-file  rw-r--r--x"
  equal(helper_mod.parse_permissions(line), nil)
end

T["parse_permissions"]["returns nil when perm chars are invalid"] = function()
  -- Contains 'z' which is not [rwx-]
  local line = "  icon  /00001 my-file  rw-r--r-z"
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
  local line = "  icon  /00002 some-file  ---------"
  equal(helper_mod.parse_permissions(line), "---------")
end

T["parse_permissions"]["returns perm string of all rwx"] = function()
  local line = "  icon  /00003 exec-file  rwxrwxrwx"
  equal(helper_mod.parse_permissions(line), "rwxrwxrwx")
end

T["parse_permissions"]["returns nil when perm block is only 8 chars"] = function()
  -- Only 8 permission characters (too short)
  local line = "  icon  /00004 my-file  rw-r--r-"
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
  local line = "  icon  /00010 apps/  rwxr-xr-x"
  equal(helper_mod.parse_is_directory(line), true)
end

T["parse_is_directory"]["returns false for ref_id entry with perm and no trailing slash"] = function()
  local line = "  icon  /00011 readme.md  rw-r--r--"
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
  local line = "  icon  /00020 apps/  rwxr-xr-x"
  equal(helper_mod.parse_name(line), "apps")
end

T["parse_name"]["preserves filename without trailing slash"] = function()
  local line = "  icon  /00021 file.txt  rw-r--r--"
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

-- ---------------------------------------------------------------------------
-- size suffix ("<n>B" real text)
-- ---------------------------------------------------------------------------

T["size suffix"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      local config = require("fyler.config")
      -- Save current values (may be nil when no setup ran yet)
      _G._test_helper_saved_values = config.values
      config.values = {
        views = { finder = { columns = { size = { enabled = true } } } },
      }
    end,
    post_case = function()
      require("fyler.config").values = _G._test_helper_saved_values
      _G._test_helper_saved_values = nil
    end,
  },
})

T["size suffix"]["parse_permissions ignores trailing size"] = function()
  local line = "  icon  /00030 my-file  rw-r--r--  11349B"
  equal(helper_mod.parse_permissions(line), "rw-r--r--")
end

T["size suffix"]["parse_name strips trailing size"] = function()
  local line = "  icon  /00031 my-file  rw-r--r--  11349B"
  equal(helper_mod.parse_name(line), "my-file")
end

T["size suffix"]["parse_name keeps filename that looks like a size"] = function()
  -- File named "100B" (200 bytes large): only the rendered suffix is stripped
  local line = "  icon  /00032 100B  rw-r--r--  200B"
  equal(helper_mod.parse_name(line), "100B")
end

T["size suffix"]["parse_is_directory handles size on files"] = function()
  local line = "  icon  /00033 readme.md  rw-r--r--  42B"
  equal(helper_mod.parse_is_directory(line), false)
end

T["size suffix"]["parse_is_directory handles directories without size"] = function()
  local line = "  icon  /00034 my-dir/  rwxr-xr-x"
  equal(helper_mod.parse_is_directory(line), true)
end

T["size suffix"]["parse_name leaves user-typed size-like names alone"] = function()
  -- New entries (no ref_id) never carry a size suffix, so no stripping
  equal(helper_mod.parse_name("  1B"), "1B")
  equal(helper_mod.parse_name("  hello/"), "hello")
end

T["size suffix"]["tampered size is ignored, perms still parsed"] = function()
  -- User edited "991B" into "991sdfpi": name and perms must still resolve,
  -- the trailing junk is never validated and never produces actions.
  local line = "  icon  /00035 deploy-packages.sh  rwxr-xr-x  991sdfpi"
  equal(helper_mod.parse_name(line), "deploy-packages.sh")
  equal(helper_mod.parse_permissions(line), "rwxr-xr-x")
end

T["size suffix"]["parse_name without size suffix still works"] = function()
  equal(helper_mod.parse_name("  icon  /00036 my-file  rw-r--r--"), "my-file")
end

return T

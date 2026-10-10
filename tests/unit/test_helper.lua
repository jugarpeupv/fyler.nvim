-- Unit tests for lua/fyler/views/finder/helper.lua
-- Layout under test: /NNNNN name[ <git>  <perms>][ | size][ | date]
-- (<icon> <name> <git>  <perms> | <size> | <date>, ref_id concealed; the git
-- slot is real single-char buffer text before the perm block, perms carry
-- an ls-style file-type prefix, only the last 9 rwx chars are parsed, and
-- git content is always ignored).

local MiniTest = require("mini.test")
local helper_mod = require("fyler.views.finder.helper")

local T = MiniTest.new_set()
local equal = MiniTest.expect.equality

-- Real renders always carry all metadata columns, so enable every flag while
-- parsing styled lines (restored afterwards).
local function flags_on()
  local config = require("fyler.config")
  _G._test_helper_saved_values = config.values
  config.values = {
    views = {
      finder = {
        columns = {
          git = { enabled = true },
          permission = { enabled = true },
          size = { enabled = true },
          creation_time = { enabled = true },
        },
      },
    },
  }
end

local function flags_restore()
  require("fyler.config").values = _G._test_helper_saved_values
  _G._test_helper_saved_values = nil
end

local FLAGS_HOOKS = { hooks = { pre_case = flags_on, post_case = flags_restore } }

-- ---------------------------------------------------------------------------
-- parse_permissions
-- ---------------------------------------------------------------------------

T["parse_permissions"] = MiniTest.new_set(FLAGS_HOOKS)

T["parse_permissions"]["returns perm string for valid line"] = function()
  -- Name first, git slot + pipe-separated perms + size + trailing date after it
  local line = "  icon  /00001 my-file ?  .rw-r--r-- | 512B | 04/10/26 13:11"
  equal(helper_mod.parse_permissions(line), "rw-r--r--")
end

T["parse_permissions"]["returns perm string for clean file with blank git slot"] = function()
  local line = "  icon  /00001 my-file    .rw-r--r-- | 512B | 04/10/26 13:11"
  equal(helper_mod.parse_permissions(line), "rw-r--r--")
end

T["parse_permissions"]["returns nil when perm is glued to trailing text"] = function()
  -- 10 valid chars but immediately followed by a letter instead of whitespace
  local line = "  icon  /00001 my-file    .rw-r--r--x | 512B | 04/10/26 13:11"
  equal(helper_mod.parse_permissions(line), nil)
end

T["parse_permissions"]["returns nil when perm chars are invalid"] = function()
  -- Contains 'z' which is not [rwx-]
  local line = "  icon  /00001 my-file    -rw-r--r-z | 512B | 04/10/26 13:11"
  equal(helper_mod.parse_permissions(line), nil)
end

T["parse_permissions"]["returns nil when no ref_id present"] = function()
  -- New entry (no /NNNNN token)
  local line = "  rw-r--r-- my-new-file"
  equal(helper_mod.parse_permissions(line), nil)
end

T["parse_permissions"]["returns nil for empty line"] = function() equal(helper_mod.parse_permissions(""), nil) end

T["parse_permissions"]["returns perm string of all dashes"] = function()
  local line = "  icon  /00002 some-file    .--------- | 09/10/26 12:15"
  equal(helper_mod.parse_permissions(line), "---------")
end

T["parse_permissions"]["returns perm string of all rwx"] = function()
  local line = "  icon  /00003 exec-file +  .rwxrwxrwx | 100B | 09/10/26 12:15"
  equal(helper_mod.parse_permissions(line), "rwxrwxrwx")
end

T["parse_permissions"]["ignores the type prefix, returns last 9"] = function()
  -- A directory block on a file line: the 'd' is dropped, never an action
  local line = "  icon  /00005 some-file ~  drwxr-xr-x | 100B | 09/10/26 12:15"
  equal(helper_mod.parse_permissions(line), "rwxr-xr-x")
end

T["parse_permissions"]["accepts link type prefix"] = function()
  local line = "  icon  /00006 some-link    lrwxrwxrwx | 100B | 09/10/26 12:15"
  equal(helper_mod.parse_permissions(line), "rwxrwxrwx")
end

T["parse_permissions"]["returns nil when type prefix is invalid"] = function()
  -- 'q' is neither a type char nor an rwx char
  local line = "  icon  /00007 some-file    qrwxrwxrwx | 100B | 09/10/26 12:15"
  equal(helper_mod.parse_permissions(line), nil)
end

T["parse_permissions"]["returns nil when perm block is only 8 chars"] = function()
  -- Only 8 permission characters (too short)
  local line = "  icon  /00004 my-file    rw-r--r- | 512B | 04/10/26 13:11"
  equal(helper_mod.parse_permissions(line), nil)
end

-- ---------------------------------------------------------------------------
-- parse_is_directory
-- ---------------------------------------------------------------------------

T["parse_is_directory"] = MiniTest.new_set(FLAGS_HOOKS)

T["parse_is_directory"]["returns true for new entry with trailing slash"] = function()
  local line = "  new-dir/"
  equal(helper_mod.parse_is_directory(line), true)
end

T["parse_is_directory"]["returns false for new entry without trailing slash"] = function()
  local line = "  new-file"
  equal(helper_mod.parse_is_directory(line), false)
end

T["parse_is_directory"]["returns true for ref_id entry with perm/date and trailing slash"] = function()
  local line = "  icon  /00010 apps/ ~  drwxr-xr-x | 09/10/26 12:15"
  equal(helper_mod.parse_is_directory(line), true)
end

T["parse_is_directory"]["returns false for ref_id entry with perm/date and no trailing slash"] = function()
  local line = "  icon  /00011 readme.md    .rw-r--r-- | 42B | 09/10/26 12:15"
  equal(helper_mod.parse_is_directory(line), false)
end

T["parse_is_directory"]["returns false for ref_id entry with destroyed date"] = function()
  -- No parseable trailing date: invalid line, never a directory.
  local line = "  icon  /00012 my-dir/   rwxr-xr-x"
  equal(helper_mod.parse_is_directory(line), false)
end

T["parse_is_directory"]["returns false for empty line"] = function() equal(helper_mod.parse_is_directory(""), false) end

-- ---------------------------------------------------------------------------
-- parse_name (regression checks related to trailing-slash stripping)
-- ---------------------------------------------------------------------------

T["parse_name"] = MiniTest.new_set(FLAGS_HOOKS)

T["parse_name"]["strips trailing slash from directory name"] = function()
  local line = "  icon  /00020 apps/ ~  drwxr-xr-x | 09/10/26 12:15"
  equal(helper_mod.parse_name(line), "apps")
end

T["parse_name"]["preserves filename without trailing slash"] = function()
  local line = "  icon  /00021 file.txt    .rw-r--r-- | 100B | 09/10/26 12:15"
  equal(helper_mod.parse_name(line), "file.txt")
end

T["parse_name"]["preserves names with spaces with metadata around them"] = function()
  local line = "  icon  /00022 bigger name here.txt ?  .rw-r--r-- | 2B | 09/10/26 12:15"
  equal(helper_mod.parse_name(line), "bigger name here.txt")
end

T["parse_name"]["preserves names containing pipes"] = function()
  local line = "  icon  /00023 a | b.txt    .rw-r--r-- | 34B | 09/10/26 12:15"
  equal(helper_mod.parse_name(line), "a | b.txt")
end

T["parse_name"]["returns name for new entry (no ref_id)"] = function()
  local line = "  new-file.txt"
  equal(helper_mod.parse_name(line), "new-file.txt")
end

-- ---------------------------------------------------------------------------
-- columns off: no metadata rendered, whole remainder is the name
-- ---------------------------------------------------------------------------

T["columns off"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      local config = require("fyler.config")
      _G._test_helper_saved_values = config.values
      config.values = {
        views = {
          finder = {
            columns = {
              git = { enabled = false },
              permission = { enabled = false },
              size = { enabled = false },
              creation_time = { enabled = false },
            },
          },
        },
      }
    end,
    post_case = function()
      require("fyler.config").values = _G._test_helper_saved_values
      _G._test_helper_saved_values = nil
    end,
  },
})

T["columns off"]["parse_name returns remainder as name"] = function()
  equal(helper_mod.parse_name("  icon  /00022 plain-name"), "plain-name")
end

T["columns off"]["parse_name strips trailing slash"] = function()
  equal(helper_mod.parse_name("  icon  /00023 plain-dir/"), "plain-dir")
end

T["columns off"]["parse_is_directory detects slash"] = function()
  equal(helper_mod.parse_is_directory("  icon  /00012 my-dir/"), true)
  equal(helper_mod.parse_is_directory("  icon  /00013 my-file"), false)
end

T["columns off"]["parse_permissions returns nil"] = function()
  equal(helper_mod.parse_permissions("  icon  /00001 my-file  rw-r--r--"), nil)
end

-- ---------------------------------------------------------------------------
-- trailing date layout: icon name perms | size | date
-- ---------------------------------------------------------------------------

T["date layout"] = MiniTest.new_set(FLAGS_HOOKS)

T["date layout"]["tampered size is ignored, name still parsed"] = function()
  -- User edited the mid-line size into junk: name and perms still resolve,
  -- the junk is never validated and never produces actions.
  local line = "  icon  /00035 deploy-packages.sh ~  drwxr-xr-x | 991sdfpi | 04/10/26 13:11"
  equal(helper_mod.parse_name(line), "deploy-packages.sh")
  equal(helper_mod.parse_permissions(line), "rwxr-xr-x")
  local _, _, err = helper_mod.parse_entry(line)
  equal(err, nil)
end

T["date layout"]["parse_name keeps filename that looks like a size"] = function()
  -- File named "100B" (200 bytes large): only the mid-line size is ignored
  local line = "  icon  /00032 100B    .rw-r--r-- | 200B | 04/10/26 13:11"
  equal(helper_mod.parse_name(line), "100B")
end

T["date layout"]["missing date is tolerated (cross-instance paste)"] = function()
  -- A pasted line may lack the date when copied from an instance with the
  -- date column hidden: name and perms still resolve, no error.
  local line = "  icon  /00036 my-file    .rw-r--r-- | 512B"
  local name, perm, err = helper_mod.parse_entry(line)
  equal(name, "my-file")
  equal(perm, "rw-r--r--")
  equal(err, nil)
end

T["date layout"]["missing date and size is tolerated (cross-instance paste)"] = function()
  -- Copied from an instance showing only permissions: still valid.
  local line = "  icon  /00016 assets/    drwxr-xr-x"
  local name, perm, err = helper_mod.parse_entry(line)
  equal(name, "assets/")
  equal(perm, "rwxr-xr-x")
  equal(err, nil)
end

T["date layout"]["date-only remainder is an error"] = function()
  -- Nothing but a date after the id: nothing to parse, must abort.
  local line = "  icon  /00037 04/10/26 13:11"
  local name, _, err = helper_mod.parse_entry(line)
  equal(name, nil)
  equal(err ~= nil, true)
end

T["date layout"]["parse_name leaves user-typed lines alone"] = function()
  -- New entries (no ref_id) are taken as-is, whatever they contain.
  equal(helper_mod.parse_name("  1B"), "1B")
  equal(helper_mod.parse_name("  hello/"), "hello")
end

-- ---------------------------------------------------------------------------
-- permission column off: size/date still stripped, remainder is the name
-- ---------------------------------------------------------------------------

T["perm off"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      local config = require("fyler.config")
      _G._test_helper_saved_values = config.values
      config.values = {
        views = {
          finder = {
            columns = {
              git = { enabled = false },
              permission = { enabled = false },
              size = { enabled = true },
              creation_time = { enabled = true },
            },
          },
        },
      }
    end,
    post_case = function()
      require("fyler.config").values = _G._test_helper_saved_values
      _G._test_helper_saved_values = nil
    end,
  },
})

T["perm off"]["parse_name strips size and date suffix"] = function()
  equal(helper_mod.parse_name("  icon  /00040 my-file | 512B | 04/10/26 13:11"), "my-file")
end

T["perm off"]["parse_name keeps pipes inside the filename"] = function()
  equal(helper_mod.parse_name("  icon  /00041 a | b.txt | 34B | 04/10/26 13:11"), "a | b.txt")
end

T["perm off"]["parse_permissions returns nil"] = function()
  equal(helper_mod.parse_permissions("  icon  /00040 my-file | 512B | 04/10/26 13:11"), nil)
end

-- ---------------------------------------------------------------------------
-- git slot: real text before the permission block, always ignored
-- ---------------------------------------------------------------------------

T["git slot"] = MiniTest.new_set(FLAGS_HOOKS)

T["git slot"]["tampered git char is ignored, name and perms still parsed"] = function()
  -- User edited the git slot into junk: silent no-op, like size edits.
  local line = "  icon  /00050 my-file Z  .rw-r--r-- | 512B | 04/10/26 13:11"
  equal(helper_mod.parse_name(line), "my-file")
  equal(helper_mod.parse_permissions(line), "rw-r--r--")
  local _, _, err = helper_mod.parse_entry(line)
  equal(err, nil)
end

T["git slot"]["deleted git slot still parses when symbols shift"] = function()
  -- Every configured symbol lands in the same slot and parses identically.
  for _, sym in ipairs({ "?", "+", "~", "D", "R", "C", "!", " " }) do
    local line = string.format("  icon  /00051 my-file %s  .rw-r--r-- | 512B | 04/10/26 13:11", sym)
    equal(helper_mod.parse_name(line), "my-file")
    equal(helper_mod.parse_permissions(line), "rw-r--r--")
  end
end

T["git slot"]["missing perm block with git present is not a perm"] = function()
  -- Git slot alone ("<name>  <git>") yields no perms; the slot never leaks
  -- into the name.
  local line = "  icon  /00052 my-file ? | 512B | 04/10/26 13:11"
  equal(helper_mod.parse_name(line), "my-file")
  equal(helper_mod.parse_permissions(line), nil)
end

T["git slot"]["parse_name strips git slot when perm column is off"] = function()
  local config = require("fyler.config")
  local saved = config.values
  config.values = {
    views = {
      finder = {
        columns = {
          git = { enabled = true },
          permission = { enabled = false },
          size = { enabled = true },
          creation_time = { enabled = true },
        },
      },
    },
  }
  equal(helper_mod.parse_name("  icon  /00053 my-file ? | 512B | 04/10/26 13:11"), "my-file")
  equal(helper_mod.parse_permissions("  icon  /00053 my-file ? | 512B | 04/10/26 13:11"), nil)
  config.values = saved
end

return T

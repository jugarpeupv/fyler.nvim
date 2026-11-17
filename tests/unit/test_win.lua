local MiniTest = require("mini.test")
local Win = require("fyler.lib.win")

local T = MiniTest.new_set()
local equal = MiniTest.expect.equality

T["cache_decorations keys decorations by ref_id"] = function()
  local win = setmetatable({}, Win)
  win:cache_decorations({ "  icon  /00042 alpha/  .rw-r--r--" }, {
    { line = 0, col_start = 2, col_end = 6, highlight_group = "FylerFSDirectoryIcon", priority = 100 },
    { line = 0, col_start = 6, col_end = 15, conceal = "" },
    { line = 0, col_start = 15, col_end = 21, highlight_group = "FylerFSDirectoryName" },
  }, { { line = 0, col = 0, virt_text = { { "M", "FylerGitModified" } }, virt_text_pos = "eol" } })

  local entry = win:get_cached_decorations(42)
  equal(entry.tail, "alpha/  .rw-r--r--")
  -- The leading indentation is not part of the comparable technical prefix.
  equal(entry.tech, "icon  /00042 ")
  equal(entry.name_start, 15)
  equal(#entry.highlights, 3)
  -- Highlight ranges are stored relative to the filename start.
  equal(entry.highlights[1].rel_start, -13)
  equal(entry.highlights[3].rel_start, 0)
  equal(entry.highlights[3].rel_end, 6)
  equal(#entry.extmarks, 1)
  equal(entry.extmarks[1].win_col, nil)
end

T["cache_decorations keeps win_col for column extmarks"] = function()
  local win = setmetatable({}, Win)
  win:cache_decorations(
    { "icon  /00042 alpha" },
    {},
    { { line = 0, col = 54, virt_text = { { "" } }, virt_text_pos = "win_col" } }
  )
  equal(win:get_cached_decorations(42).extmarks[1].win_col, 54)
end

return T

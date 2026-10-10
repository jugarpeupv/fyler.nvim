local MiniTest = require("mini.test")
local config = require("fyler.config")
config.setup()
local ui = require("fyler.views.finder.ui")

local T = MiniTest.new_set()
local equal = MiniTest.expect.equality

T["highlight_cache for gitignored directories"] = function()
  config.setup({
    views = {
      finder = {
        columns = {
          git = { enabled = true },
        },
      },
    },
  })

  -- Simulate cached gitignored status for ref_id 10
  ui.highlight_cache[10] = "FylerFSIgnored"

  local tree_node = {
    path = "/test",
    children = {
      {
        name = "ignored-folder",
        type = "directory",
        path = "/test/ignored-folder",
        ref_id = 10,
        children = {
          {
            name = "child-file",
            type = "file",
            path = "/test/ignored-folder/child-file",
            ref_id = 11,
          },
          {
            name = "child-folder",
            type = "directory",
            path = "/test/ignored-folder/child-folder",
            ref_id = 12,
            children = {},
          },
        },
      },
      {
        name = "normal-folder",
        type = "directory",
        path = "/test/normal-folder",
        ref_id = 20,
        children = {},
      },
    },
  }

  local first_pass_result = nil
  ui.files(tree_node, function(comp)
    if not first_pass_result then first_pass_result = comp end
  end)

  -- first_pass_result should have the immediate Pass 1 render
  -- children: Row({ Column(files_column) })
  local files_column = first_pass_result.children[1].children[1].children

  -- files_column[1] is "../"
  -- files_column[2] is "ignored-folder/"
  -- child 4 in the row is name_text
  local ignored_row = files_column[2]
  local ignored_name = ignored_row.children[4]
  equal(ignored_name.value, "ignored-folder/")
  equal(ignored_name.option.highlight, "FylerFSIgnored")

  -- files_column[3] is "child-folder/" (sorted directories first)
  local child_dir_row = files_column[3]
  local child_dir_name = child_dir_row.children[4]
  equal(child_dir_name.value, "child-folder/")
  equal(child_dir_name.option.highlight, "FylerFSIgnored")

  -- files_column[4] is "child-file"
  local child_file_row = files_column[4]
  local child_file_name = child_file_row.children[4]
  equal(child_file_name.value, "child-file")
  equal(child_file_name.option.highlight, "FylerGitIgnored")

  -- files_column[5] is "normal-folder/"
  local normal_row = files_column[5]
  local normal_name = normal_row.children[4]
  equal(normal_name.value, "normal-folder/")
  equal(normal_name.option.highlight, "FylerFSDirectoryName")

  -- Cleanup
  ui.highlight_cache[10] = nil
end

T["highlight_cache for collapsed gitignored directory"] = function()
  config.setup({
    views = {
      finder = {
        columns = {
          git = { enabled = true },
        },
      },
    },
  })

  ui.highlight_cache[10] = "FylerFSIgnored"

  local tree_node = {
    path = "/test",
    children = {
      {
        name = "ignored-folder",
        type = "directory",
        path = "/test/ignored-folder",
        ref_id = 10,
        open = false,
        children = {},
      },
    },
  }

  local first_pass_result = nil
  ui.files(tree_node, function(comp)
    if not first_pass_result then first_pass_result = comp end
  end)

  local files_column = first_pass_result.children[1].children[1].children
  local ignored_row = files_column[2]
  local ignored_name = ignored_row.children[4]
  equal(ignored_name.value, "ignored-folder/")
  equal(ignored_name.option.highlight, "FylerFSIgnored")

  ui.highlight_cache[10] = nil
end

return T

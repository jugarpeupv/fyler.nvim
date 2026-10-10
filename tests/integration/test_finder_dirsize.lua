local helper = require("tests.helper")

local nvim = helper.new_neovim()
local equal = helper.equal

local T = helper.new_set({
  hooks = {
    pre_case = function()
      nvim.setup({
        views = {
          finder = {
            columns_order = {},
            confirm_simple = true,
          },
        },
      })
    end,
    post_case_once = nvim.stop,
  },
})

-- Build a temp tree and open fyler on it. Returns the temp dir path.
local function make_tree(name, build)
  local temp_dir = vim.fs.joinpath(_G.FYLER_TEMP_DIR, name)
  vim.fn.delete(temp_dir, "rf")
  vim.fn.mkdir(temp_dir, "p")

  require("mini.test").finally(function() vim.fn.delete(temp_dir, "rf") end)

  build(temp_dir)

  nvim.forward_lua("require('fyler').open")({ dir = temp_dir, kind = "replace" })
  vim.uv.sleep(100)

  return temp_dir
end

local function find_line(pattern)
  for _, line in ipairs(nvim.get_lines(0, 0, -1, false)) do
    if line:find(pattern, 1, true) then return line end
  end
  return nil
end

T["DirSize"] = helper.new_set()

T["DirSize"]["Shows Exact File Sizes"] = function()
  make_tree("dirsize_data", function(temp_dir)
    -- writefile appends "\n": 999 + 1 = 1000 bytes
    vim.fn.writefile({ string.rep("a", 999) }, temp_dir .. "/afile")
    vim.uv.fs_chmod(temp_dir .. "/afile", tonumber("644", 8))
  end)

  local line = find_line("afile")
  equal(line ~= nil, true)
  -- Git slot is real text before the perm block: "afile <git>  .rw-r--r--".
  equal(line:match("afile .  %.rw%-r%--r%-- | 1000B |") ~= nil, true)
end

T["DirSize"]["Shows Directory Entry Size Ls Style"] = function()
  make_tree("dirsize_dir", function(temp_dir)
    vim.fn.mkdir(temp_dir .. "/subdir/nested", "p")
    vim.fn.writefile({ string.rep("a", 999) }, temp_dir .. "/subdir/file1")
    vim.uv.fs_chmod(temp_dir .. "/subdir", tonumber("755", 8))
  end)

  -- Like `ls -la`: a directory shows its own entry size (platform-dependent
  -- value) with a 'd' type prefix — assert the size block is present.
  -- The git slot sits between the name and the perm block.
  local line = find_line("subdir/")
  equal(line ~= nil, true)
  equal(line:match("subdir/ .  drwxr%-xr%-x | ") ~= nil, true)
  equal(line:match("| [%d.]+[BKMGT] |") ~= nil, true)
end

return T

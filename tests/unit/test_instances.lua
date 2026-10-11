local MiniTest = require("mini.test")
local config = require("fyler.config")
config.setup()
local finder = require("fyler.views.finder")

local T = MiniTest.new_set()
local equal = MiniTest.expect.equality

T["instances without maximum limit"] = function()
  -- Clean up any existing instances
  for inst in finder.iter_instances() do
    inst:close()
  end

  local temp_dir1 = vim.fs.joinpath(_G.FYLER_TEMP_DIR, "inst1")
  local temp_dir2 = vim.fs.joinpath(_G.FYLER_TEMP_DIR, "inst2")
  local temp_dir3 = vim.fs.joinpath(_G.FYLER_TEMP_DIR, "inst3")
  local temp_dir4 = vim.fs.joinpath(_G.FYLER_TEMP_DIR, "inst4")
  vim.fn.mkdir(temp_dir1, "p")
  vim.fn.mkdir(temp_dir2, "p")
  vim.fn.mkdir(temp_dir3, "p")
  vim.fn.mkdir(temp_dir4, "p")

  MiniTest.finally(function()
    for inst in finder.iter_instances() do
      inst:close()
    end
    vim.fn.delete(temp_dir1, "rf")
    vim.fn.delete(temp_dir2, "rf")
    vim.fn.delete(temp_dir3, "rf")
    vim.fn.delete(temp_dir4, "rf")
  end)

  -- Open 4 different directories
  local f1 = finder.open_at(temp_dir1, "split_right")
  equal(f1 ~= nil, true)
  equal(f1.slot, 1)

  local f2 = finder.open_at(temp_dir2, "split_right")
  equal(f2 ~= nil, true)
  equal(f2.slot, 2)

  local f3 = finder.open_at(temp_dir3, "split_right")
  equal(f3 ~= nil, true)
  equal(f3.slot, 3)

  local f4 = finder.open_at(temp_dir4, "split_right")
  equal(f4 ~= nil, true)
  equal(f4.slot, 4)

  -- Closing f2 should free slot 2
  f2:close()

  -- Next opened instance should reuse the lowest free slot (2)
  local temp_dir5 = vim.fs.joinpath(_G.FYLER_TEMP_DIR, "inst5")
  vim.fn.mkdir(temp_dir5, "p")
  MiniTest.finally(function() vim.fn.delete(temp_dir5, "rf") end)

  local f5 = finder.open_at(temp_dir5, "split_right")
  equal(f5 ~= nil, true)
  equal(f5.slot, 2)
end

return T

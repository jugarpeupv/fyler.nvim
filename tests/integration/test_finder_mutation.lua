local helper = require("tests.helper")

local nvim = helper.new_neovim()
local equal = helper.equal

local function make_tree(children, name)
  local temp_dir = vim.fs.joinpath(_G.FYLER_TEMP_DIR, name or "data")
  vim.fn.mkdir(temp_dir, "p")

  require("mini.test").finally(function() vim.fn.delete(temp_dir, "rf") end)

  for _, path in ipairs(children) do
    local path_ext = temp_dir .. "/" .. path
    if vim.endswith(path, "/") then
      vim.fn.mkdir(path_ext)
    else
      vim.fn.writefile({}, path_ext)
    end
  end

  return temp_dir
end

local function check_tree(dir, ref_tree)
  nvim.lua("_G.dir = " .. vim.inspect(dir))
  local tree = nvim.lua([[
    local read_dir
    read_dir = function(path, res)
      res = res or {}
      local fs = vim.loop.fs_scandir(path)
      local name, fs_type = vim.loop.fs_scandir_next(fs)
      while name do
        local cur_path = path .. '/' .. name
        table.insert(res, cur_path .. (fs_type == 'directory' and '/' or ''))
        if fs_type == 'directory' then read_dir(cur_path, res) end
        name, fs_type = vim.loop.fs_scandir_next(fs)
      end
      return res
    end
    local dir_len = _G.dir:len()
    return vim.tbl_map(function(p) return p:sub(dir_len + 2) end, read_dir(_G.dir))
  ]])
  table.sort(tree)
  local ref = vim.deepcopy(ref_tree)
  table.sort(ref)
  equal(tree, ref)
end

local T = helper.new_set({
  hooks = {
    pre_case = function() nvim.setup_no_perm({ views = { finder = { columns_order = {} } } }) end,
    post_case_once = nvim.stop,
  },
})

T["Each WinKind Can"] = helper.new_set({
  parametrize = {
    { "float" },
    { "replace" },
    { "split_left" },
    { "split_left_most" },
    { "split_above" },
    { "split_above_all" },
    { "split_right" },
    { "split_right_most" },
    { "split_below" },
    { "split_below_all" },
  },
})

T["Each WinKind Can"]["Handle Empty Actions"] = function(kind)
  local path = make_tree({})
  nvim.forward_lua("require('fyler').open")({ dir = path, kind = kind })
  vim.uv.sleep(20)
  nvim.set_lines(0, -1, -1, false, { "" })
  nvim.cmd("write")
  vim.uv.sleep(20)
  check_tree(path, {})
end

T["Each WinKind Can"]["Do Create Actions"] = function(kind)
  local path = make_tree({})
  nvim.forward_lua("require('fyler').open")({ dir = path, kind = kind })
  vim.uv.sleep(20)
  nvim.set_lines(0, 2, 2, false, { "new-file", "new-dir/" })
  nvim.cmd("write")
  nvim.type_keys("y")
  vim.uv.sleep(20)
  check_tree(path, { "new-file", "new-dir/" })
end

T["Each WinKind Can"]["Do Delete Actions"] = function(kind)
  local path = make_tree({ "a-file", "a-dir/", "b-dir/", "b-dir/ba-file" })
  nvim.forward_lua("require('fyler').open")({ dir = path, kind = kind })
  vim.uv.sleep(20)
  nvim.set_lines(0, 0, -1, false, {})
  nvim.cmd("write")
  nvim.type_keys("y")
  vim.uv.sleep(20)
  check_tree(path, {})
end

T["Each WinKind Can"]["Do Move Actions"] = function(kind)
  local path = make_tree({ "a-file", "a-dir/", "b-dir/", "b-dir/ba-file" })
  nvim.forward_lua("require('fyler').open")({ dir = path, kind = kind })
  vim.uv.sleep(20)
  -- With the filename last, a realistic rename inserts the suffix before a
  -- trailing "/" (directories) or appends it (files).
  local function add_suffix(line, suffix)
    if vim.endswith(line, "/") then return line:sub(1, -2) .. suffix .. "/" end
    return line .. suffix
  end
  -- stylua: ignore
  nvim.set_lines(0, 0, -1, false, vim.tbl_map(function(line) return add_suffix(line, "-renamed") end, nvim.get_lines(0, 0, -1, false)))
  nvim.cmd("write")
  nvim.type_keys("y")
  vim.uv.sleep(20)
  check_tree(path, { "a-file-renamed", "a-dir-renamed/", "b-dir-renamed/", "b-dir-renamed/ba-file" })
end

T["Each WinKind Can"]["Do Copy Actions"] = function(kind)
  local path = make_tree({ "a-file", "a-dir/", "b-dir/", "b-dir/ba-file" })
  nvim.forward_lua("require('fyler').open")({ dir = path, kind = kind })
  vim.uv.sleep(20)
  local function add_suffix(line, suffix)
    if vim.endswith(line, "/") then return line:sub(1, -2) .. suffix .. "/" end
    return line .. suffix
  end
  -- Duplicate entry lines only: copying the header or "../" rows would
  -- create junk entries (they carry no ref_id).
  local copies = {}
  for i, line in ipairs(nvim.get_lines(0, 0, -1, false)) do
    if i > 2 then table.insert(copies, add_suffix(line, "-copied")) end
  end
  -- stylua: ignore
  nvim.set_lines(0, -1, -1, false, copies)
  nvim.cmd("write")
  nvim.type_keys("y")
  vim.uv.sleep(20)
  check_tree(path, {
    "a-file",
    "a-dir/",
    "b-dir/",
    "b-dir/ba-file",
    "a-file-copied",
    "a-dir-copied/",
    "b-dir-copied/",
    "b-dir-copied/ba-file",
  })
end

T["Each WinKind Can"]["Cancel Mutation Restores Buffer"] = function(kind)
  local path = make_tree({ "a-file", "b-file" })
  nvim.forward_lua("require('fyler').open")({ dir = path, kind = kind })
  vim.uv.sleep(20)
  local orig_lines = nvim.get_lines(0, 0, -1, false)
  local copies = {}
  for i, line in ipairs(orig_lines) do
    if i > 2 then table.insert(copies, line .. "-pasted") end
  end
  nvim.set_lines(0, -1, -1, false, copies)
  nvim.cmd("write")
  nvim.type_keys("n")
  vim.uv.sleep(50)
  local current_lines = nvim.get_lines(0, 0, -1, false)
  equal(current_lines, orig_lines)
  check_tree(path, { "a-file", "b-file" })
end

T["Each WinKind Can"]["Cross-instance copy cancels and confirms"] = function(kind)
  local path1 = make_tree({ "file-from-inst1" }, "data1")
  local path2 = make_tree({ "file-in-inst2" }, "data2")

  nvim.lua(string.format(
    [[
    local finder = require('fyler.views.finder')
    _G.inst1 = finder.instance(1, %s)
    _G.inst2 = finder.instance(2, %s)
    _G.inst1:open(%s)
    _G.inst2:open(%s)
  ]],
    vim.inspect(path1),
    vim.inspect(path2),
    vim.inspect(kind),
    vim.inspect(kind)
  ))
  vim.uv.sleep(50)

  local inst1_buf = nvim.lua("return _G.inst1.win.bufnr")
  local inst2_buf = nvim.lua("return _G.inst2.win.bufnr")
  local inst1_lines = nvim.get_lines(inst1_buf, 0, -1, false)
  local copied_line = nil
  for _, line in ipairs(inst1_lines) do
    if line:find("file%-from%-inst1") then
      copied_line = line
      break
    end
  end
  equal(copied_line ~= nil, true)

  local inst2_win = nvim.lua("return _G.inst2.win.winid")
  nvim.lua(string.format("vim.api.nvim_set_current_win(%d)", inst2_win))
  local inst2_orig_lines = nvim.get_lines(inst2_buf, 0, -1, false)
  nvim.set_lines(inst2_buf, -1, -1, false, { copied_line })

  -- Verify cross-instance copy resolver output has cross_instance = true and absolute paths
  local actions = nvim.lua("return _G.inst2.files:diff_with_buffer()")
  equal(#actions, 1)
  equal(actions[1].type, "copy")
  equal(actions[1].cross_instance, true)
  equal(actions[1].src, path1 .. "/file-from-inst1")
  equal(actions[1].dst, path2 .. "/file-from-inst1")

  -- Verify confirmation display operation has absolute destination after " > "
  local dst_display = nvim.lua([[
    local Path = require("fyler.lib.path")
    local cwd = Path.new(_G.inst2:getcwd())
    local display_ops = vim.tbl_map(function(operation)
      local result = vim.deepcopy(operation)
      local rel_src = not operation.cross_instance and cwd:relative(operation.src)
      if rel_src then
        result.src = rel_src
        result.dst = cwd:relative(operation.dst) or operation.dst
      else
        result.src = operation.src
        result.dst = operation.dst
      end
      return result
    end, _G.inst2.files:diff_with_buffer())
    return display_ops[1].dst
  ]])
  equal(dst_display, path2 .. "/file-from-inst1")

  -- Cancel confirmation by typing 'n'
  nvim.cmd("write")
  nvim.type_keys("n")
  vim.uv.sleep(50)
  equal(nvim.get_lines(inst2_buf, 0, -1, false), inst2_orig_lines)
  check_tree(path2, { "file-in-inst2" })

  -- Confirm mutation by typing 'y'
  nvim.set_lines(inst2_buf, -1, -1, false, { copied_line })
  nvim.cmd("write")
  nvim.type_keys("y")
  vim.uv.sleep(50)
  check_tree(path2, { "file-in-inst2", "file-from-inst1" })
end

-- TODO: Still need to implement compound actions testing but first need to find a way to reproduce the bug

return T

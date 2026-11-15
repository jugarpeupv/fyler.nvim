local helper = require("tests.helper")

local nvim = helper.new_neovim()
local equal = helper.equal

local opts = { views = { finder = { win = { kind = "replace" } } } }

local function make_dirs(names)
  local dirs = {}
  for _, name in ipairs(names) do
    local dir = vim.fs.joinpath(_G.FYLER_TEMP_DIR, name)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({}, vim.fs.joinpath(dir, "a.txt"))
    require("mini.test").finally(function() vim.fn.delete(dir, "rf") end)
    dirs[#dirs + 1] = dir
  end
  return dirs
end

local function session_path(name)
  local path = vim.fs.joinpath(_G.FYLER_TEMP_DIR, name .. ".vim")
  require("mini.test").finally(function() vim.fn.delete(path) end)
  return path
end

local function open(dir, kind)
  nvim.lua(string.format([[require("fyler").open({ dir = %s, kind = %s })]], vim.inspect(dir), vim.inspect(kind)))
  vim.uv.sleep(300)
end

local function save_session(path)
  nvim.lua(string.format([[vim.cmd("mksession! " .. vim.fn.fnameescape(%s))]], vim.inspect(path)))
  vim.uv.sleep(200)
end

local function load_session(path)
  nvim.lua(string.format([[vim.cmd("source " .. vim.fn.fnameescape(%s))]], vim.inspect(path)))
  vim.uv.sleep(1200)
end

local T = helper.new_set({
  hooks = {
    pre_case = function() nvim.setup_no_perm(opts) end,
    post_case_once = nvim.stop,
  },
})

T["Restores a single view in place"] = function()
  local dir = make_dirs({ "session_single" })[1]
  local session = session_path("session_single")

  open(dir, "replace")
  save_session(session)

  -- :mksession cannot store acwrite buffer contents: it writes an empty
  -- placeholder that keeps the fyler:// URI as the buffer name.
  helper.match_pattern(table.concat(vim.fn.readfile(session), "\n"), "file fyler://")

  nvim.setup_no_perm(opts)
  load_session(session)

  equal(nvim.bo.filetype, "fyler")
  equal(nvim.bo.buftype, "acwrite")
  equal(nvim.lua([[return require("fyler").get_current_dir()]]), dir)
  equal(nvim.lua([[return #vim.api.nvim_tabpage_list_wins(0)]]), 1)
  equal(
    nvim.lua([[
      return #vim.tbl_filter(function(b)
        return vim.api.nvim_buf_get_name(b):match("^fyler://") ~= nil
      end, vim.api.nvim_list_bufs())
    ]]),
    1
  )
end

T["Restores every instance with its slot and directory"] = function()
  local dirs = make_dirs({ "session_multi_1", "session_multi_2" })
  local d1, d2 = dirs[1], dirs[2]
  local session = session_path("session_multi")

  open(d1, "replace")
  open(d2, "split_right")
  save_session(session)

  nvim.setup_no_perm(opts)
  load_session(session)

  local result = nvim.lua([[
    local out = { windows = #vim.api.nvim_tabpage_list_wins(0), fyler_buffers = 0 }
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):match("^fyler://") then
        out.fyler_buffers = out.fyler_buffers + 1
        assert(vim.bo[b].buftype == "acwrite", "restored buffer is not a fyler buffer")
      end
    end
    for inst in require("fyler.views.finder").iter_instances() do
      if inst:isopen() then out["slot" .. inst.slot] = inst:getcwd() end
    end
    return out
  ]])

  equal(result.windows, 2)
  equal(result.fyler_buffers, 2)
  equal(result.slot1, d1)
  equal(result.slot2, d2)
end

T["Restores when the session is loaded while fyler is open"] = function()
  local dir = make_dirs({ "session_in_place" })[1]
  local session = session_path("session_in_place")

  open(dir, "replace")
  save_session(session)

  -- Loading a session in place (what persistence.nvim's load() does) makes
  -- :mksession recreate `file fyler://...` while the old buffer still exists,
  -- which would fail with E95 without closing the views first.
  load_session(session)

  equal(nvim.bo.filetype, "fyler")
  equal(nvim.bo.buftype, "acwrite")
  equal(nvim.lua([[return require("fyler").get_current_dir()]]), dir)
end

T["Restores the cursor on the same entry"] = function()
  local dir = vim.fs.joinpath(_G.FYLER_TEMP_DIR, "session_cursor")
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(vim.fs.joinpath(dir, "sub"), "p")
  vim.fn.writefile({}, vim.fs.joinpath(dir, "a.txt"))
  vim.fn.writefile({}, vim.fs.joinpath(dir, "sub", "b.txt"))
  require("mini.test").finally(function() vim.fn.delete(dir, "rf") end)
  local session = session_path("session_cursor")

  open(dir, "replace")
  -- Put the cursor on a nested entry (this also expands its parent).
  nvim.lua(string.format(
    [[
    local inst
    for i in require("fyler.views.finder").iter_instances() do
      if i:isopen() then inst = i end
    end
    inst:reveal(%s)
  ]],
    vim.inspect(dir .. "/sub/b.txt")
  ))
  vim.uv.sleep(800)

  save_session(session)
  helper.match_pattern(table.concat(vim.fn.readfile(session), "\n"), "set_pending_cursors")

  -- Both SessionWritePost and persistence.nvim's SavePost fire for a save;
  -- the marker must not be appended twice.
  nvim.lua([[vim.api.nvim_exec_autocmds("User", { pattern = "PersistenceSavePost" })]])
  local saved = table.concat(vim.fn.readfile(session), "\n")
  equal(select(2, saved:gsub("set_pending_cursors", "")), 1)

  nvim.setup_no_perm(opts)
  load_session(session)

  local result = nvim.lua([[
    local inst
    for i in require("fyler.views.finder").iter_instances() do
      if i:isopen() then inst = i end
    end
    local entry = inst:cursor_node_entry()
    local row = vim.api.nvim_win_get_cursor(inst.win.winid)[1]
    return { name = entry and entry.name, line = vim.api.nvim_buf_get_lines(inst.win.bufnr, row - 1, row, false)[1] }
  ]])
  equal(result.name, "b.txt")
  helper.match_pattern(result.line or "", "b%.txt")
end

T["Restores when the plugin is set up after the session"] = function()
  local dir = make_dirs({ "session_lazy" })[1]
  local session = session_path("session_lazy")

  open(dir, "replace")
  save_session(session)

  -- Simulate lazy loading: restart without setup, load the session, then set
  -- the plugin up. The placeholder must be picked up at setup time.
  nvim.restart({ "-u", "tests/minimal_init.lua" })
  nvim.set_size(20, 80)
  load_session(session)
  nvim.lua(string.format([[require("fyler").setup(%s)]], vim.inspect(opts)))
  vim.uv.sleep(800)

  equal(nvim.bo.filetype, "fyler")
  equal(nvim.bo.buftype, "acwrite")
  equal(nvim.lua([[return require("fyler").get_current_dir()]]), dir)
end

return T

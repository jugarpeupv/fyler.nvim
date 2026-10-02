local helper = require("tests.helper")

local nvim = helper.new_neovim()
local equal = helper.equal

local function make_tree()
  local temp_dir = vim.fs.joinpath(_G.FYLER_TEMP_DIR, "preview_data")
  vim.fn.delete(temp_dir, "rf")
  vim.fn.mkdir(temp_dir .. "/sub", "p")

  require("mini.test").finally(function() vim.fn.delete(temp_dir, "rf") end)

  vim.fn.writefile({ "alpha one" }, temp_dir .. "/a.txt")
  vim.fn.writefile({ "beta one" }, temp_dir .. "/b.txt")

  return temp_dir
end

local T = helper.new_set({
  hooks = {
    pre_case = function() nvim.setup_no_perm({ views = { finder = { columns_order = {} } } }) end,
    post_case_once = nvim.stop,
  },
})

T["Preview"] = helper.new_set()

-- Toggle opens a vsplit showing the file under the cursor; toggling again
-- closes it. CursorMoved is fired explicitly: headless child nvim does not
-- emit it for `:normal` motions without a screen.
T["Preview"]["Toggle Opens Closes And Follows Cursor"] = function()
  local path = make_tree()

  nvim.lua(string.format([[require("fyler").open({ dir = %s, kind = "replace" })]], vim.inspect(path)))
  vim.uv.sleep(800)

  local result = nvim.lua([[
    local inst
    for i in require("fyler.views.finder").iter_instances() do
      if i:isopen() then inst = i break end
    end
    assert(inst, "no open finder instance")
    vim.api.nvim_set_current_win(inst.win.winid)
    local function row_with(pat)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(inst.win.bufnr, 0, -1, false)) do
        if l:match(pat) then return i end
      end
    end
    local function preview_text()
      if not inst.preview then return nil end
      return table.concat(vim.api.nvim_buf_get_lines(inst.preview.bufnr, 0, -1, false), "|")
    end
    local function move_to(row)
      vim.api.nvim_win_set_cursor(inst.win.winid, { row, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = inst.win.bufnr })
    end
    local out = {}
    -- <C-p> is mapped by default in fyler buffers (string form: "" when missing)
    move_to(row_with("a%.txt"))
    out.has_map = vim.fn.maparg("<C-p>", "n", false, false) ~= ""
    inst:action_call("n_toggle_preview")
    vim.wait(300)
    out.wins_open = #vim.api.nvim_tabpage_list_wins(0)
    out.first = preview_text()
    out.focus = vim.api.nvim_get_current_win() == inst.win.winid
    move_to(row_with("b%.txt"))
    vim.wait(400)
    out.second = preview_text()
    inst:action_call("n_toggle_preview")
    vim.wait(200)
    out.wins_closed = #vim.api.nvim_tabpage_list_wins(0)
    out.cleared = inst.preview == nil
    return out
  ]])

  equal(result.has_map, true)
  equal(result.wins_open, 2)
  equal(result.first, "alpha one")
  equal(result.focus, true)
  equal(result.second, "beta one")
  equal(result.wins_closed, 1)
  equal(result.cleared, true)
end

return T

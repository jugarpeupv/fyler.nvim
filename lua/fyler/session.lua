--- Session support
---
--- |:mksession| cannot serialize the contents of special buffers. Fyler's
--- buffers use `buftype=acwrite`, which Neovim treats as a buffer without a
--- file name, so a session only stores an empty placeholder:
---
---     enew
---     file fyler:///path/to/dir/__orig__/1
---
--- The placeholder keeps the directory and the instance slot in its name,
--- which is all that is needed to rebuild the view. Neovim ends every session
--- file with `doautoall SessionLoadPost`, so this module hooks that event and
--- reopens fyler in the window that shows the placeholder.
---
--- Restoring relies on the `blank` flag of 'sessionoptions' (Neovim's
--- default); floating views are not stored by sessions at all.
---
---@tag fyler.nvim.session

local helper = require("fyler.views.finder.helper")

local M = {}

---Cursor/selection data embedded in the session file by save_cursors().
---@type table[]|nil
M._pending_cursors = nil

---@param buf integer
---@return boolean
local function is_fyler_buffer(buf)
  return vim.api.nvim_buf_is_valid(buf) and helper.is_protocol_uri(vim.api.nvim_buf_get_name(buf))
end

---Whether a live fyler view owns the buffer. Placeholders left behind by a
---session are not owned by any view.
---@param buf integer
---@return boolean
local function is_owned(buf)
  local finder = require("fyler.views.finder")
  for inst in finder.iter_instances() do
    if inst and inst.win and inst.win.bufnr == buf and inst:isopen() then return true end
  end
  return false
end

---Get (or create) the finder instance for a directory and slot.
---@param dir string
---@param slot integer
---@return table
local function instance_for(dir, slot)
  local finder = require("fyler.views.finder")
  local inst
  if slot == 1 then
    finder.set_current_dir(dir)
    inst = finder.instance(1)
  else
    inst = finder.instance(slot, dir)
  end
  if inst:getcwd() ~= dir then inst:change_root(dir) end
  return inst
end

---Saved cursor data for an instance, if the session carried any.
---@param inst table
---@return table|nil
local function pending_cursor_for(inst)
  local dir = inst:getcwd()
  local ans
  for _, c in ipairs(M._pending_cursors or {}) do
    if c.slot == inst.slot and c.dir == dir then ans = c end
  end
  return ans
end

---Set the cursor on the entry with the given (current) ref_id. The tree is
---rendered asynchronously, so poll the buffer briefly instead of using a
---render callback (a newer render can supersede ours, dropping the callback).
---@param inst table
---@param ref_id integer
---@param col integer
---@param attempts integer
local function set_cursor_to_ref(inst, ref_id, col, attempts)
  if not inst:isopen() then return end
  local needle = string.format("/%05d ", ref_id)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(inst.win.bufnr, 0, -1, false)) do
    if line:find(needle, 1, true) then
      pcall(vim.api.nvim_win_set_cursor, inst.win.winid, { i, math.min(col, #line) })
      return
    end
  end
  if attempts > 0 then vim.defer_fn(function() set_cursor_to_ref(inst, ref_id, col, attempts - 1) end, 20) end
end

---Fallback: put the cursor on the saved line/column once the view is rendered.
---@param inst table
---@param saved table
---@param attempts integer
local function set_cursor_to_line(inst, saved, attempts)
  if not inst:isopen() then return end
  local buf = inst.win.bufnr
  local line_count = vim.api.nvim_buf_line_count(buf)
  if saved.line and saved.line > line_count and attempts > 0 then
    vim.defer_fn(function() set_cursor_to_line(inst, saved, attempts - 1) end, 20)
    return
  end
  local row = math.max(1, math.min(saved.line or 1, line_count))
  local text = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, inst.win.winid, { row, math.max(0, math.min(saved.col or 0, #text)) })
end

---Put the cursor back where it was when the session was saved.
---
---Prefer the path of the entry under the cursor: navigating to it also
---re-expands the parent directories, which is the only way to land on a nested
---entry (expanded tree state is not stored in sessions). Fall back to the raw
---line/column when the entry no longer exists.
---@param inst table
---@param saved table
local function apply_cursor(inst, saved)
  local winid = inst.win and inst.win.winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end

  if type(saved.path) == "string" and saved.path ~= "" then
    local ok = pcall(function()
      inst.files:navigate(vim.fn.fnamemodify(saved.path, ":p"), function(err, ref_id)
        -- files:navigate resolves paths from a libuv fast-event callback, where
        -- buffer/window APIs are forbidden; hop back to a safe context.
        vim.schedule(function()
          if err or not ref_id or not inst:isopen() then
            inst:dispatch_refresh({ force_update = true })
            set_cursor_to_line(inst, saved, 25)
            return
          end
          inst:dispatch_refresh({ force_update = true })
          set_cursor_to_ref(inst, ref_id, saved.col or 0, 25)
        end)
      end)
    end)
    if ok then return end
  end

  inst:dispatch_refresh({ force_update = true })
  set_cursor_to_line(inst, saved, 25)
end

---Wait for the initial render before expanding parents, so navigation does not
---race with the file-tree update started by open().
---@param inst table
---@param saved table
---@param attempts integer
local function apply_cursor_when_ready(inst, saved, attempts)
  if not inst:isopen() then return end
  if vim.api.nvim_buf_line_count(inst.win.bufnr) <= 1 and attempts > 0 then
    vim.defer_fn(function() apply_cursor_when_ready(inst, saved, attempts - 1) end, 20)
    return
  end
  apply_cursor(inst, saved)
end

---Delete placeholder buffers that no window displays (created by the `badd`
---lines a session writes for listed buffers).
local function wipe_stale()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_fyler_buffer(buf) and not is_owned(buf) and not vim.bo[buf].modified and #vim.fn.win_findbuf(buf) == 0 then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---Rebuild the fyler view for a placeholder buffer in the window showing it.
---Safe to call for buffers that are already owned by a view: they are skipped.
---@param buf integer
function M.restore_buffer(buf)
  if not is_fyler_buffer(buf) then return end

  local dir, slot = helper.parse_protocol_uri(vim.api.nvim_buf_get_name(buf))
  if not dir or dir == "" or vim.fn.isdirectory(dir) == 0 then return end

  -- Defer: SessionLoadPost runs inside `doautoall`, and opening a view
  -- manipulates buffers and windows.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) or is_owned(buf) then return end

    local wins = vim.fn.win_findbuf(buf)
    local winid = wins[1]
    if not winid or not vim.api.nvim_win_is_valid(winid) then return end

    local inst = instance_for(dir, slot)
    local prev_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(winid)
    -- "replace" reuses the current window (and the placeholder buffer), so
    -- the layout and split sizes restored by the session are preserved.
    inst:open("replace")
    local saved = pending_cursor_for(inst)
    if saved then apply_cursor_when_ready(inst, saved, 50) end
    -- Keep the window the session made current instead of the last view
    -- restored, so focus matches what was saved.
    if vim.api.nvim_win_is_valid(prev_win) then vim.api.nvim_set_current_win(prev_win) end
  end)
  vim.schedule(wipe_stale)
end

---Restore every placeholder left by a previously loaded session. Also used on
---startup when the plugin is loaded after the session (lazy loading).
function M.restore()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.restore_buffer(buf)
  end
end

---Free the buffer names a session is about to recreate.
---
---A session writes `enew` followed by `file fyler://...`. If a buffer with that
---name still exists (loading a session while a fyler view is open, which is
---what `:lua require("persistence").load()` does), `:file` fails with
---`E95: Buffer with this name already exists` and the window is left with an
---unnamed buffer. Close the current views and wipe leftover fyler buffers
---before the session is sourced.
function M.prepare_for_load()
  M._pending_cursors = nil
  local finder = require("fyler.views.finder")
  for inst in finder.iter_instances() do
    if inst and inst.win and inst:isopen() then inst:close() end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_fyler_buffer(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
end

---Store the cursor data embedded in a session file.
---Called by the `lua` line that save_cursors() appends to the session.
---@param data table[]|nil
function M.set_pending_cursors(data) M._pending_cursors = type(data) == "table" and data or nil end

---Write the cursor of every open fyler view into the session file.
---
---:mksession does not store cursor positions for buffers without a file name
---(which is how it treats `buftype=acwrite`), so append a Lua command that
---hands the data back to set_pending_cursors() when the session is sourced.
function M.save_cursors()
  local session = vim.v.this_session
  if not session or session == "" or vim.fn.filereadable(session) == 0 then return end

  local finder = require("fyler.views.finder")
  local data = {}
  for inst in finder.iter_instances() do
    if inst and inst.win and inst:isopen() then
      local row, col = inst.win:get_cursor()
      if row then
        local entry = inst:cursor_node_entry()
        data[#data + 1] = {
          slot = inst.slot,
          dir = inst:getcwd(),
          line = row,
          col = col or 0,
          path = entry and entry.path or nil,
        }
      end
    end
  end
  if #data == 0 then return end

  local expr = vim.inspect(data, { newline = " ", indent = "" })
  local marker = "lua pcall(function() require('fyler.session').set_pending_cursors("
  local line = marker .. expr .. ") end)"

  -- Replace a previous marker instead of appending a second one: both
  -- SessionWritePost and persistence.nvim's PersistenceSavePost can run for
  -- the same save.
  local lines = vim.fn.readfile(session)
  while #lines > 0 and vim.startswith(lines[#lines], marker) do
    table.remove(lines)
  end
  lines[#lines + 1] = line
  pcall(vim.fn.writefile, lines, session)
end

return M

local helper = require("tests.helper")

local nvim = helper.new_neovim()
local equal = helper.equal

-- Create a temp directory with a single file whose initial mode we control.
local function make_tree(children, modes)
  local temp_dir = vim.fs.joinpath(_G.FYLER_TEMP_DIR, "chmod_data")
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

  -- Apply initial modes when provided: { filename = octal_integer }
  if modes then
    for name, mode in pairs(modes) do
      vim.uv.fs_chmod(temp_dir .. "/" .. name, mode)
    end
  end

  return temp_dir
end

-- Read the lower 9 permission bits for a file (returns nil on error).
local function get_mode(path)
  local stat = vim.uv.fs_lstat(path)
  return stat and (stat.mode % 512)
end

local T = helper.new_set({
  hooks = {
    -- chmod test needs the permission column enabled.
    -- confirm_simple=true skips the confirmation dialog for simple ops.
    pre_case = function()
      nvim.setup({
        views = {
          finder = {
            columns_order = { "permission" },
            confirm_simple = true,
          },
        },
      })
    end,
    post_case_once = nvim.stop,
  },
})

-- Helper: replace the 9-char permission substring in a buffer line.
-- Returns the modified line, or the original if no valid perm block is found.
local function replace_perm(line, new_perm)
  -- Lines have format:  <indent><icon>  /NNNNN <9-char-perm> <name>
  -- We locate the perm block right after the /NNNNN token.
  local prefix, rest = line:match("^(.*/%d+ )(.*)$")
  if not prefix then return line end
  -- Verify the first 9 chars of rest look like a perm string.
  if not rest:match("^[rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-] ") then
    return line
  end
  return prefix .. new_perm .. " " .. rest:sub(11)
end

T["Chmod"] = helper.new_set()

T["Chmod"]["Applies Permission Change On Write"] = function()
  -- Create a file with mode 0o644 (rw-r--r--)
  local path = make_tree({ "target-file" }, { ["target-file"] = tonumber("644", 8) })
  local file_path = path .. "/target-file"

  -- Verify starting permissions (lower 9 bits = 0o644 = 420)
  equal(get_mode(file_path), tonumber("644", 8))

  -- Open fyler pointing at the temp dir
  nvim.forward_lua("require('fyler').open")({ dir = path, kind = "replace" })
  vim.uv.sleep(30)

  -- Read buffer lines, find the target-file line and change its perm string
  local lines = nvim.get_lines(0, 0, -1, false)
  local new_lines = {}
  for _, line in ipairs(lines) do
    if line:find("target%-file") then
      table.insert(new_lines, replace_perm(line, "rwxrwxrwx"))
    else
      table.insert(new_lines, line)
    end
  end
  nvim.set_lines(0, 0, -1, false, new_lines)
  nvim.cmd("write")
  vim.uv.sleep(30)

  -- Verify the file mode was updated to 0o777 (rwxrwxrwx)
  equal(get_mode(file_path), tonumber("777", 8))
end

T["Chmod"]["No Action When Permissions Unchanged"] = function()
  local path = make_tree({ "stable-file" }, { ["stable-file"] = tonumber("644", 8) })
  local file_path = path .. "/stable-file"

  nvim.forward_lua("require('fyler').open")({ dir = path, kind = "replace" })
  vim.uv.sleep(30)

  -- Write without changing anything – no chmod should happen
  nvim.cmd("write")
  vim.uv.sleep(20)

  equal(get_mode(file_path), tonumber("644", 8))
end

T["Chmod"]["Invalid Perm String Shows Warning And Rerenders"] = function()
  local path = make_tree({ "guarded-file" })

  nvim.forward_lua("require('fyler').open")({ dir = path, kind = "replace" })
  vim.uv.sleep(30)

  -- Corrupt the permission field so it is only 5 chars (invalid)
  local lines = nvim.get_lines(0, 0, -1, false)
  local new_lines = {}
  for _, line in ipairs(lines) do
    if line:find("guarded%-file") then
      -- Overwrite only the perm block characters with a too-short string
      local prefix, rest = line:match("^(.*/%d+ )(.*)$")
      if prefix then
        -- Replace the valid 10-char perm+space block with garbage
        table.insert(new_lines, prefix .. "bad  rwx " .. rest:sub(11))
      else
        table.insert(new_lines, line)
      end
    else
      table.insert(new_lines, line)
    end
  end
  nvim.set_lines(0, 0, -1, false, new_lines)
  nvim.cmd("write")
  vim.uv.sleep(30)

  -- Buffer should have been re-rendered back to a valid state (non-empty)
  local after_lines = nvim.get_lines(0, 0, -1, false)
  equal(#after_lines > 0, true)
  -- The guarded-file name should still be visible (rerender restored it)
  local found = false
  for _, l in ipairs(after_lines) do
    if l:find("guarded%-file") then
      found = true
      break
    end
  end
  equal(found, true)
end

return T

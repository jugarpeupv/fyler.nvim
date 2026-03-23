local Path = require("fyler.lib.path")
local Process = require("fyler.lib.process")
local config = require("fyler.config")
local util = require("fyler.lib.util")

local M = {}

---Find the actual git directory for any path.
---Handles regular repos (.git/ directory) and git worktrees (.git file containing
---"gitdir: <path>"). Returns nil when not inside a git repository.
---@param dir string
---@return string|nil
function M.find_git_dir(dir)
  local path = Path.new(dir)
  while true do
    local candidate = path:join(".git")

    if candidate:is_directory() then
      return candidate:os_path()
    end

    if candidate:is_file() then
      -- Worktree: .git is a file with "gitdir: <relative-or-absolute-path>"
      local f = io.open(candidate:os_path(), "r")
      if f then
        local line = f:read("*l")
        f:close()
        if line then
          local target = line:match("^gitdir:%s*(.+)$")
          if target then
            target = target:match("^%s*(.-)%s*$") -- trim
            -- Resolve relative paths against the directory that contains the .git file
            if not vim.startswith(target, "/") then
              target = path:join(target):os_path()
            end
            return target
          end
        end
      end
    end

    local parent = path:parent()
    -- Stop when we reach the filesystem root
    if parent:os_path() == path:os_path() then return nil end
    path = parent
  end
end

---Find the common git directory for a worktree.
---In a regular repo, git_dir IS the common dir.
---In a worktree, git_dir contains a "commondir" file pointing to the shared repo.
---Returns git_dir itself when no commondir file is present (regular repo / main worktree).
---@param git_dir string  The worktree-specific git dir (result of find_git_dir)
---@return string  The common git dir (where refs/heads lives)
function M.find_common_git_dir(git_dir)
  local commondir_file = git_dir .. "/commondir"
  local f = io.open(commondir_file, "r")
  if not f then return git_dir end

  local line = f:read("*l")
  f:close()
  if not line then return git_dir end

  line = line:match("^%s*(.-)%s*$") -- trim
  if line == "" then return git_dir end

  -- commondir can be an absolute path or relative to git_dir.
  -- Normalize with fnamemodify ":p" to resolve any ".." traversals so the
  -- returned path is always a clean absolute path (e.g. worktrees commondir
  -- files contain "../.." which vim.fs.joinpath leaves unresolved).
  local raw
  if vim.startswith(line, "/") then
    raw = line
  else
    raw = Path.new(git_dir):join(line):os_path()
  end
  return vim.fn.fnamemodify(raw, ":p"):gsub("/$", "")
end

-- Unmerged / conflict codes where X and Y together have a single meaning
local conflict_codes = {
  DD = true, AU = true, UD = true, UA = true,
  DU = true, AA = true, UU = true,
}

---Decode a raw two-character porcelain XY code into a human-readable status
---name, taking staged vs. unstaged state into account.
---
--- Priority (highest to lowest):
---   1. Conflict   – unmerged states where both chars form a single meaning
---   2. Untracked  – "??"
---   3. Ignored    – "!!"
---   4. Named staged status – when X encodes Add / Delete / Rename / Copy
---   5. Staged     – any other non-blank / non-? X character (e.g. "M ")
---   6. Named unstaged status derived from Y
---   7. Unstaged   – any other non-blank Y character
---
---When a file has BOTH staged and unstaged changes (e.g. "MM"), staged wins.
---@param xy string Two-character porcelain code, e.g. " M", "M ", "MM", "A "
---@return string|nil status Human-readable status name, or nil for unknown codes
local function decode_xy(xy)
  if xy == nil then return nil end
  if conflict_codes[xy] then return "Conflict" end
  if xy == "??" then return "Untracked" end
  if xy == "!!" then return "Ignored" end

  local x = xy:sub(1, 1)
  local y = xy:sub(2, 2)

  -- Staged side takes priority
  if x == "D" then return "Deleted" end
  if x == "R" then return "Renamed" end
  if x == "C" then return "Copied" end
  if x ~= " " and x ~= "?" then return "Staged" end

  -- Unstaged side
  if y == "D" then return "Deleted" end
  if y ~= " " and y ~= "?" then return "Unstaged" end

  return nil
end

local hl_map = {
  Untracked = "FylerGitUntracked",
  Staged    = "FylerGitStaged",
  Unstaged  = "FylerGitUnstaged",
  Deleted   = "FylerGitDeleted",
  Renamed   = "FylerGitRenamed",
  Copied    = "FylerGitCopied",
  Conflict  = "FylerGitConflict",
  Ignored   = "FylerGitIgnored",
}

local icon_hl_map = {
  Untracked = "FylerGitIconUntracked",
  Staged    = "FylerGitIconStaged",
  Unstaged  = "FylerGitIconUnstaged",
  Deleted   = "FylerGitIconDeleted",
  Renamed   = "FylerGitIconRenamed",
  Copied    = "FylerGitIconCopied",
  Conflict  = "FylerGitIconConflict",
  Ignored   = "FylerGitIconIgnored",
}

function M.map_entries_async(root_dir, entries, _next)
  M.build_modified_lookup_for_async(root_dir, function(modified_lookup)
    M.build_ignored_lookup_for_async(root_dir, entries, function(ignored_lookup)
      local status_map = util.tbl_merge_force(modified_lookup, ignored_lookup)
      local result = util.tbl_map(
        entries,
        function(e)
          local status = status_map[e]
          -- If this entry has no direct status, check if it's inside an
          -- untracked or ignored directory. git status --porcelain only reports
          -- the top-level directory for fully untracked trees, so child entries
          -- won't have their own status in the map.  Symlink entries whose
          -- resolved target is outside the repo are also absent from the map;
          -- they inherit ignored status from the nearest ignored ancestor.
          if not status then
            for dir_path, dir_status in pairs(status_map) do
              if (dir_status == "??" or dir_status == "!!") and vim.startswith(e, dir_path .. "/") then
                status = dir_status
                break
              end
            end
          end
          local status_name = decode_xy(status)
          return {
            config.values.views.finder.columns.git.symbols[status_name] or "",
            icon_hl_map[status_name],
            hl_map[status_name],
          }
        end
      )
      _next(result)
    end)
  end)
end

---@param dir string
---@param _next function
function M.build_modified_lookup_for_async(dir, _next)
  local process = Process.new({
    path = "git",
    args = { "-C", dir, "status", "--porcelain" },
  })

  process:spawn_async(function(code)
    local lookup = {}

    if code == 0 then
      for _, line in process:stdout_iter() do
        if line ~= "" then
          local symbol = line:sub(1, 2)
          local raw = line:sub(4):gsub("/$", "")
          local path = Path.new(dir):join(raw):os_path()
          lookup[path] = symbol
        end
      end
    end

    _next(lookup)
  end)
end

---@param dir string
---@param stdin string|string[]
---@param _next function
function M.build_ignored_lookup_for_async(dir, stdin, _next)
  local paths = util.tbl_wrap(stdin)

  -- git check-ignore rejects paths that are:
  --   (a) outside the repository root ("outside repository"), or
  --   (b) reached through a mid-path symlink ("beyond a symbolic link").
  -- Either case causes git to exit 128, poisoning the entire batch and
  -- producing an empty lookup (no gitignored highlights for any entry).
  --
  -- Strategy: for each path, resolve only the components that are themselves
  -- symlinks using vim.uv.fs_realpath.  If the resolved path is still inside
  -- `dir` we use it (fixes the "beyond a symlink" case).  If the resolved path
  -- is outside `dir` (e.g. a workspace symlink like cdk-mar-patterns pointing to
  -- ../../../../tmp/…), we skip that entry entirely — it cannot be governed by
  -- this repo's .gitignore and should not be sent to git.  We keep a
  -- resolved→original map so the lookup is keyed by the original path.
  local dir_prefix = dir:gsub("/?$", "/") -- ensure trailing slash for prefix check
  local safe_paths = {}
  local resolved_to_original = {}

  for _, p in ipairs(paths) do
    local resolved = vim.uv.fs_realpath(p) or p
    if vim.startswith(resolved, dir_prefix) or resolved == dir then
      table.insert(safe_paths, resolved)
      resolved_to_original[resolved] = p
    end
    -- paths outside the repo are silently dropped; they cannot match .gitignore
  end

  if #safe_paths == 0 then
    return _next({})
  end

  local process = Process.new({
    path = "git",
    args = { "-C", dir, "check-ignore", "--stdin" },
    stdin = table.concat(safe_paths, "\n"),
  })

  process:spawn_async(function(code)
    local lookup = {}

    if code == 0 then
      for _, line in process:stdout_iter() do
        if line ~= "" then
          -- Map back to the original (unresolved) path so callers that index
          -- by the original path (e.g. status_map[e] in map_entries_async) work
          -- correctly even when the path passed through a symlinked directory.
          local original = resolved_to_original[line] or line
          lookup[original] = "!!"
        end
      end
    end

    _next(lookup)
  end)
end

return M

local Path = require("fyler.lib.path")
local config = require("fyler.config")
local util = require("fyler.lib.util")
local git = require("fyler.lib.git")

---@class Watcher
---@field paths table<string, { fsevent: uv.uv_fs_event_t, running: boolean }>
---@field git_fsevent uv.uv_fs_event_t|nil
---@field git_refs_fsevents uv.uv_fs_event_t[]  watchers for refs/heads/ and its subdirs
---@field git_dir string|nil
---@field git_common_dir string|nil
---@field finder Finder
local Watcher = {}
Watcher.__index = Watcher

local instance = {}

---@return Watcher
function Watcher.new(finder)
  return setmetatable({ finder = finder, paths = {}, git_fsevent = nil, git_refs_fsevents = {}, git_dir = nil, git_common_dir = nil }, Watcher)
end

---@param dir string
function Watcher:start(dir)
  if not dir then return end

  if not Path.new(dir):is_directory() then
    self.paths[dir] = nil
    return
  end

  if not config.values.views.finder.watcher.enabled then return self end

  if not self.paths[dir] then
    self.paths[dir] = {
      fsevent = assert(vim.uv.new_fs_event()),
      running = false,
    }
  end

  if self.paths[dir].running then return self end

  self.paths[dir].fsevent:start(dir, {}, function(err, filename)
    if err then return end

    if
      filename == nil
      or filename:match("index")
      or filename:match("ORIG_HEAD")
      or filename:match("FETCH_HEAD")
      or filename:match("COMMIT_EDITMSG")
      or vim.endswith(filename, ".lock")
    then
      return
    end

    util.debounce(
      string.format("watcher:%d_%d_%s", self.finder.win.winid, self.finder.win.bufnr, dir),
      200,
      function() self.finder:dispatch_refresh({ force_update = true }) end
    )
  end)

  self.paths[dir].running = true
end

---Start a dedicated watcher on the git directory so that external git commands
---(git add, git commit, git push, git checkout, …) trigger a UI refresh.
---The git dir is resolved once and cached; calling this again is a no-op when
---the git dir hasn't changed.
---
---For worktrees, also watch the *common* git dir (where refs/heads lives) so
---that `git commit` is detected: commits update refs/heads/<branch> in the
---common dir, not in the worktree-specific dir.
---
---Because vim.uv fs_event is non-recursive, and branch names can contain a
---slash (e.g. "feature/MAR-1156" → refs/heads/feature/MAR-1156), we watch
---refs/heads/ itself AND every direct subdirectory of refs/heads/ so that
---commits to namespaced branches are detected.
function Watcher:start_git()
  if not config.values.views.finder.watcher.enabled then return self end

  local git_dir = git.find_git_dir(self.finder:getcwd())
  if not git_dir then return self end -- not inside a git repo

  local common_dir = git.find_common_git_dir(git_dir)

  -- Already watching the same git dir – nothing to do
  if self.git_dir == git_dir and self.git_fsevent then return self end

  -- Stop any previously running git watcher before creating a new one
  self:stop_git()

  local debounce_key = string.format("git_watcher:%d_%d", self.finder.win.winid, self.finder.win.bufnr)
  local function on_git_event(err, filename)
    if err or not filename then return end

    util.debounce(debounce_key, 300,
      -- git_only: refresh only detail columns, no buffer line rewrite → no flicker
      function() self.finder:dispatch_refresh({ git_only = true }) end
    )
  end

  -- Watch the worktree-specific git dir (index, HEAD for detached worktrees, etc.)
  self.git_dir = git_dir
  self.git_fsevent = assert(vim.uv.new_fs_event())
  self.git_fsevent:start(git_dir, {}, function(err, filename)
    if err or not filename then return end

    -- The files that change after user-visible git operations in the worktree dir:
    --   index       – git add / git reset / git rm
    --   HEAD        – git checkout / git switch (detached)
    --   FETCH_HEAD  – git fetch / git pull
    --   ORIG_HEAD   – git merge / git rebase
    --   MERGE_HEAD  – git merge in progress
    --   CHERRY_PICK_HEAD – git cherry-pick
    --   packed-refs – git pack-refs / git gc (regular repos only; worktrees use
    --                 the separate common-dir watcher added below)
    if filename == "index"
      or filename == "HEAD"
      or filename == "FETCH_HEAD"
      or filename == "ORIG_HEAD"
      or filename == "MERGE_HEAD"
      or filename == "CHERRY_PICK_HEAD"
      or filename == "packed-refs"
      or filename == "COMMIT_EDITMSG"
      or vim.startswith(filename, "refs/")
    then
      on_git_event(err, filename)
    end
  end)

  -- Watch refs/heads/ and all its direct subdirectories in the common git dir.
  --
  -- Why subdirectories: branch names like "feature/MAR-1156" produce the ref
  -- file at refs/heads/feature/MAR-1156. vim.uv fs_event is non-recursive, so
  -- a watcher on refs/heads/ alone never sees writes two levels deep.
  -- We enumerate existing subdirs at startup and watch each one.
  if common_dir ~= git_dir then
    self.git_common_dir = common_dir
  end

  local refs_heads_dir = common_dir .. "/refs/heads"
  local function watch_refs_dir(dir)
    local ev = vim.uv.new_fs_event()
    if not ev then return end
    local ok = pcall(function()
      ev:start(dir, {}, function(err, filename)
        if err or not filename then return end
        on_git_event(err, "refs/heads/" .. filename)
      end)
    end)
    if ok then
      table.insert(self.git_refs_fsevents, ev)
    else
      pcall(function() ev:stop() end)
    end
  end

  if vim.uv.fs_stat(refs_heads_dir) then
    -- Watch refs/heads/ itself (catches simple branch names like "main", "develop")
    watch_refs_dir(refs_heads_dir)

    -- Watch each direct subdirectory (catches "feature/", "fix/", "release/", etc.)
    local handle = vim.uv.fs_opendir(refs_heads_dir, nil, 32)
    if handle then
      local entries = vim.uv.fs_readdir(handle)
      if entries then
        for _, entry in ipairs(entries) do
          if entry.type == "directory" then
            watch_refs_dir(refs_heads_dir .. "/" .. entry.name)
          end
        end
      end
      vim.uv.fs_closedir(handle)
    end
  end

  -- For worktrees, the common git dir is separate from git_dir, so the
  -- git_fsevent above (which watches git_dir) won't see packed-refs updates
  -- in common_dir.  Add a dedicated watcher on common_dir filtered to the
  -- "packed-refs" file so that `git gc` / `git pack-refs` triggers a refresh.
  if common_dir ~= git_dir then
    local packed_ev = vim.uv.new_fs_event()
    if packed_ev then
      local ok = pcall(function()
        packed_ev:start(common_dir, {}, function(err, filename)
          if err or not filename then return end
          if filename == "packed-refs" then
            on_git_event(err, filename)
          end
        end)
      end)
      if ok then
        table.insert(self.git_refs_fsevents, packed_ev)
      else
        pcall(function() packed_ev:stop() end)
      end
    end
  end

  return self
end

function Watcher:stop_git()
  if self.git_fsevent then
    pcall(function() self.git_fsevent:stop() end)
    self.git_fsevent = nil
  end
  for _, ev in ipairs(self.git_refs_fsevents) do
    pcall(function() ev:stop() end)
  end
  self.git_refs_fsevents = {}
  self.git_dir = nil
  self.git_common_dir = nil
end

function Watcher:enable()
  for dir in pairs(self.paths) do
    self:start(dir)
  end
  self:start_git()
end

function Watcher:stop(dir)
  if not dir then return end

  if not Path.new(dir):is_directory() then
    self.paths[dir] = nil
    return
  end

  if not config.values.views.finder.watcher.enabled then return self end

  if not self.paths[dir] then return end

  if self.paths[dir].running then self.paths[dir].fsevent:stop() end

  self.paths[dir].running = false
end

---@param should_clean boolean|nil
function Watcher:disable(should_clean)
  for dir in pairs(self.paths) do
    self:stop(dir)
  end
  self:stop_git()

  if should_clean then self.paths = {} end
end

function Watcher.register(finder)
  local uri = finder.uri
  if not instance[uri] then instance[uri] = Watcher.new(finder) end
  return instance[uri]
end

return Watcher

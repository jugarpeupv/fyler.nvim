local Path = require("fyler.lib.path")
local config = require("fyler.config")
local util = require("fyler.lib.util")
local git = require("fyler.lib.git")

---@class Watcher
---@field paths table<string, { fsevent: uv.uv_fs_event_t, running: boolean }>
---@field git_fsevent uv.uv_fs_event_t|nil
---@field git_common_fsevent uv.uv_fs_event_t|nil
---@field git_dir string|nil
---@field git_common_dir string|nil
---@field finder Finder
local Watcher = {}
Watcher.__index = Watcher

local instance = {}

---@return Watcher
function Watcher.new(finder)
  return setmetatable({ finder = finder, paths = {}, git_fsevent = nil, git_common_fsevent = nil, git_dir = nil, git_common_dir = nil }, Watcher)
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
    if filename == "index"
      or filename == "HEAD"
      or filename == "FETCH_HEAD"
      or filename == "ORIG_HEAD"
      or filename == "MERGE_HEAD"
      or filename == "CHERRY_PICK_HEAD"
      or vim.startswith(filename, "refs/")
    then
      on_git_event(err, filename)
    end
  end)

  -- Watch the common git dir separately (for worktrees: refs/heads lives here).
  -- In a regular (non-worktree) repo, common_dir == git_dir so we skip the
  -- second watcher to avoid double-firing.
  --
  -- We watch refs/heads/ directly rather than common_dir root because:
  --   1. vim.uv fs_event is non-recursive by default on macOS
  --   2. refs/heads/master is 2 levels deep from common_dir
  --   3. Watching common_dir root would miss the actual file write
  if common_dir ~= git_dir then
    self.git_common_dir = common_dir
    local refs_heads_dir = common_dir .. "/refs/heads"

    -- Check the dir exists (bare repos always have it; safety guard)
    if vim.uv.fs_stat(refs_heads_dir) then
      self.git_common_fsevent = assert(vim.uv.new_fs_event())
      self.git_common_fsevent:start(refs_heads_dir, {}, function(err, filename)
        if err or not filename then return end
        -- Any write to refs/heads/* means a commit or branch update
        on_git_event(err, "refs/heads/" .. filename)
      end)
    end
  end

  return self
end

function Watcher:stop_git()
  if self.git_fsevent then
    pcall(function() self.git_fsevent:stop() end)
    self.git_fsevent = nil
  end
  if self.git_common_fsevent then
    pcall(function() self.git_common_fsevent:stop() end)
    self.git_common_fsevent = nil
  end
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

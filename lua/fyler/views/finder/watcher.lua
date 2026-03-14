local Path = require("fyler.lib.path")
local config = require("fyler.config")
local util = require("fyler.lib.util")
local git = require("fyler.lib.git")

---@class Watcher
---@field paths table<string, { fsevent: uv.uv_fs_event_t, running: boolean }>
---@field git_fsevent uv.uv_fs_event_t|nil
---@field git_dir string|nil
---@field finder Finder
local Watcher = {}
Watcher.__index = Watcher

local instance = {}

---@return Watcher
function Watcher.new(finder)
  return setmetatable({ finder = finder, paths = {}, git_fsevent = nil, git_dir = nil }, Watcher)
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
function Watcher:start_git()
  if not config.values.views.finder.watcher.enabled then return self end

  local git_dir = git.find_git_dir(self.finder:getcwd())
  if not git_dir then return self end -- not inside a git repo

  -- Already watching the same git dir – nothing to do
  if self.git_dir == git_dir and self.git_fsevent then return self end

  -- Stop any previously running git watcher before creating a new one
  self:stop_git()

  self.git_dir = git_dir
  self.git_fsevent = assert(vim.uv.new_fs_event())

  self.git_fsevent:start(git_dir, {}, function(err, filename)
    if err or not filename then return end

    -- The files that change after user-visible git operations:
    --   index       – git add / git reset / git rm
    --   HEAD        – git commit / git checkout / git switch / git merge / git rebase
    --   refs/heads  – git commit / git branch
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
      util.debounce(
        string.format("git_watcher:%d_%d", self.finder.win.winid, self.finder.win.bufnr),
        300,
        function() self.finder:dispatch_refresh({ force_update = true }) end
      )
    end
  end)

  return self
end

function Watcher:stop_git()
  if self.git_fsevent then
    pcall(function() self.git_fsevent:stop() end)
    self.git_fsevent = nil
  end
  self.git_dir = nil
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

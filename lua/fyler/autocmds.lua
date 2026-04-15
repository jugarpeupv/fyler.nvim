local M = {}

local augroup = vim.api.nvim_create_augroup("fyler_augroup_global", { clear = true })

function M.setup(config)
  local fyler = require("fyler")
  local helper = require("fyler.views.finder.helper")
  local util = require("fyler.lib.util")
  local Path = require("fyler.lib.path")

  config = config or {}

  if config.values.views.finder.default_explorer then
    -- Disable NETRW plugin
    vim.g.loaded_netrw = 1
    vim.g.loaded_netrwPlugin = 1

    -- Clear NETRW auto commands if NETRW loaded before disable
    vim.cmd("silent! autocmd! FileExplorer *")
    vim.cmd("autocmd VimEnter * ++once silent! autocmd! FileExplorer *")

    vim.api.nvim_create_autocmd("BufEnter", {
      group = augroup,
      pattern = "*",
      desc = "Hijack directory buffers for fyler",
      callback = function(args)
        local bufname = vim.api.nvim_buf_get_name(args.buf)
        if Path.new(bufname):is_directory() or helper.is_protocol_uri(bufname) then
          vim.schedule(function()
            if util.get_buf_option(args.buf, "filetype") == "fyler" then return end

            if vim.api.nvim_buf_is_valid(args.buf) then vim.api.nvim_buf_delete(args.buf, { force = true }) end

            fyler.open({ dir = helper.normalize_uri(bufname) })
          end)
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "BufReadCmd", "SessionLoadPost" }, {
      group = augroup,
      pattern = "fyler://*",
      desc = "Open fyler protocol URIs",
      callback = function(args)
        local bufname = vim.api.nvim_buf_get_name(args.buf)
        if helper.is_protocol_uri(bufname) then
          local finder_instance = require("fyler.views.finder").instance(bufname)
          if not finder_instance:isopen() then vim.schedule_wrap(fyler.open)({ dir = bufname }) end
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    desc = "Adjust highlight groups with respect to colorscheme",
    callback = function() require("fyler.lib.hl").setup() end,
  })

  if config.values.views.finder.follow_current_file then
    vim.api.nvim_create_autocmd("BufEnter", {
      group = augroup,
      pattern = "*",
      desc = "Track current focused buffer in finder",
      callback = function(arg)
        if helper.is_protocol_uri(arg.file) or arg.file == "" then return end

        vim.schedule(function()
          if util.get_buf_option(arg.buf, "filetype") ~= "fyler" then fyler.navigate(arg.file) end
        end)
      end,
    })
  end

  -- Prevent foreign buffers from taking over the fyler window.
  -- When any buffer is loaded into the fyler window (via gf, :e, LSP go-to-def,
  -- etc.) we immediately restore the fyler buffer in that window and open the
  -- file in a proper editor window instead.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "*",
    desc = "Prevent foreign buffers from opening inside the fyler window",
    callback = function(args)
      -- Only act on real, named, non-fyler buffers
      if util.get_buf_option(args.buf, "filetype") == "fyler" then return end
      local bufname = vim.api.nvim_buf_get_name(args.buf)
      if bufname == "" or helper.is_protocol_uri(bufname) then return end

      local finder = require("fyler.views.finder")
      local finder_instance = finder.instance and finder.instance()
      if not finder_instance or not finder_instance:isopen() then return end

      local fyler_winid = finder_instance.win and finder_instance.win.winid
      local fyler_bufnr = finder_instance.win and finder_instance.win.bufnr
      if not fyler_winid or not vim.api.nvim_win_is_valid(fyler_winid) then return end
      if vim.api.nvim_get_current_win() ~= fyler_winid then return end

      -- A foreign buffer has entered the fyler window. Redirect it.
      vim.schedule(function()
        -- Safety checks: still in fyler window and finder is still open
        if not vim.api.nvim_win_is_valid(fyler_winid) then return end
        if not finder_instance:isopen() then return end
        if vim.api.nvim_get_current_win() ~= fyler_winid then return end

        -- Restore the fyler buffer in its window
        if fyler_bufnr and vim.api.nvim_buf_is_valid(fyler_bufnr) then
          vim.api.nvim_win_set_buf(fyler_winid, fyler_bufnr)
        end

        -- Find an existing editor window (any window that is not the fyler window)
        local tabpage = vim.api.nvim_get_current_tabpage()
        local wins = vim.api.nvim_tabpage_list_wins(tabpage)
        local target_win = nil
        for _, wid in ipairs(wins) do
          if wid ~= fyler_winid and vim.api.nvim_win_is_valid(wid) then
            local cfg = vim.api.nvim_win_get_config(wid)
            -- Skip floating windows
            if cfg.relative == "" then
              target_win = wid
              break
            end
          end
        end

        if target_win then
          -- Open the file in the existing editor window
          vim.api.nvim_set_current_win(target_win)
          vim.cmd("edit " .. vim.fn.fnameescape(bufname))
        else
          -- No editor window exists: create a vertical split beside fyler
          vim.api.nvim_set_current_win(fyler_winid)
          vim.cmd("rightbelow vsplit " .. vim.fn.fnameescape(bufname))
        end
      end)
    end,
  })
end

return M

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
          local _, slot = helper.parse_protocol_uri(bufname)
          local finder_instance = require("fyler.views.finder").instance(slot)
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

  -- Prevent foreign buffers from taking over any fyler window (original or secondary).
  -- When any buffer is loaded into a fyler window (via gf, :e, LSP go-to-def, etc.)
  -- we immediately restore that fyler buffer in its window and open the file in a
  -- proper editor window instead.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "*",
    desc = "Prevent foreign buffers from opening inside any fyler window",
    callback = function(args)
      -- Only act on real, named, non-fyler buffers
      if util.get_buf_option(args.buf, "filetype") == "fyler" then return end
      local bufname = vim.api.nvim_buf_get_name(args.buf)
      if bufname == "" or helper.is_protocol_uri(bufname) then return end

      local finder_mod = require("fyler.views.finder")
      local current_win = vim.api.nvim_get_current_win()

      -- Find the fyler instance (if any) whose window is the current window
      local matched_instance = nil
      for inst in finder_mod.iter_instances() do
        if inst and inst:isopen() then
          local fyler_winid = inst.win and inst.win.winid
          if fyler_winid and vim.api.nvim_win_is_valid(fyler_winid) and current_win == fyler_winid then
            matched_instance = inst
            break
          end
        end
      end

      if not matched_instance then return end

      local fyler_winid = matched_instance.win.winid
      local fyler_bufnr = matched_instance.win.bufnr

      -- A foreign buffer has entered a fyler window. Redirect it.
      vim.schedule(function()
        -- Safety checks
        if not vim.api.nvim_win_is_valid(fyler_winid) then return end
        if not matched_instance:isopen() then return end
        if vim.api.nvim_get_current_win() ~= fyler_winid then return end

        -- Restore the fyler buffer in its window
        if fyler_bufnr and vim.api.nvim_buf_is_valid(fyler_bufnr) then
          vim.api.nvim_win_set_buf(fyler_winid, fyler_bufnr)
        end

        -- Find an existing editor window (any non-fyler, non-floating window)
        local tabpage = vim.api.nvim_get_current_tabpage()
        local wins = vim.api.nvim_tabpage_list_wins(tabpage)
        local all_fyler_winids = {}
        for inst in finder_mod.iter_instances() do
          if inst and inst.win and inst.win.winid then
            all_fyler_winids[inst.win.winid] = true
          end
        end

        local target_win = nil
        for _, wid in ipairs(wins) do
          if not all_fyler_winids[wid] and vim.api.nvim_win_is_valid(wid) then
            local cfg = vim.api.nvim_win_get_config(wid)
            if cfg.relative == "" then
              target_win = wid
              break
            end
          end
        end

        if target_win then
          vim.api.nvim_set_current_win(target_win)
          vim.cmd("edit " .. vim.fn.fnameescape(bufname))
        else
          vim.api.nvim_set_current_win(fyler_winid)
          vim.cmd("rightbelow vsplit " .. vim.fn.fnameescape(bufname))
        end
      end)
    end,
  })
end

return M

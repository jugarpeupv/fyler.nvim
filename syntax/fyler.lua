vim.cmd([[
  if exists("b:current_syntax")
    finish
  endif

  syn match FylerReferenceId /\/\d\+ / conceal
  syn match FylerPermissions /  [rwx-]\{9\}$/ containedin=ALL

  let b:current_syntax = "Fyler"
]])

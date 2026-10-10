vim.cmd([[
  if exists("b:current_syntax")
    finish
  endif

  " Ref_ids are always /NNNNN (5+ digits). The looser /\\d\\+ would also
  " match the /YY portion of inline dates (DD/MM/YY HH:MM) and conceal it.
  syn match FylerReferenceId /\/\d\{5,} / conceal
  " Permissions are ls-style 10-char blocks (".rw-r--r--", "drwxr-xr-x")
  " sitting after the filename with the size/date text trailing behind
  " them. A real-text git status slot may precede them (" ?  .rw-r--r--"),
  " so anchor on a single leading space instead of two.
  syn match FylerPermissions / \zs[%.dlcbps?-]\?[rwx-]\{9}\ze\(\s\|$\)/ containedin=ALL

  let b:current_syntax = "Fyler"
]])

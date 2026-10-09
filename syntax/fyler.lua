vim.cmd([[
  if exists("b:current_syntax")
    finish
  endif

  " Ref_ids are always /NNNNN (5+ digits). The looser /\\d\\+ would also
  " match the /YY portion of inline dates (DD/MM/YY HH:MM) and conceal it.
  syn match FylerReferenceId /\/\d\{5,} / conceal
  " Permissions are ls-style 10-char blocks (".rw-r--r--", "drwxr-xr-x")
  " sitting after the filename with the size/date text trailing behind
  " them, so anchor on a trailing whitespace-or-EOL instead of EOL alone.
  syn match FylerPermissions /  [%.dlcbps?-]\?[rwx-]\{9}\ze\(\s\|$\)/ containedin=ALL

  let b:current_syntax = "Fyler"
]])

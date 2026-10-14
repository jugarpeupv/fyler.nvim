vim.cmd([[
  if exists("b:current_syntax")
    finish
  endif

  " Ref_ids are always /NNNNN (5+ digits). The looser /\\d\\+ would also
  " match the /YY portion of inline dates (DD/MM/YY HH:MM) and conceal it.
  syn match FylerReferenceId /\/\d\{5,} / conceal
  " Permissions are ls-style 10-char blocks (".rw-r--r--", "drwxr-xr-x")
  " sitting after the filename with the size/date text trailing behind
  " them. Git status is virtual text (never buffer text), so buffer lines
  " always look the same: anchor on a single leading space.
  syn match FylerPermissions / \zs[%.dlcbps?-]\?[rwx-]\{9}\ze\(\s\|$\)/ containedin=ALL

  let b:current_syntax = "Fyler"
]])

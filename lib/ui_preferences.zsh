# Local TUI preferences belong to the user, independently of saved jobs and
# remote servers. Load once; curses re-entry must retain this process's choice.
typeset -gi UI_PREFERENCES_LOADED=0

ui_preferences_load() {
  emulate -L zsh
  (( UI_PREFERENCES_LOADED )) && return 0
  UI_PREFERENCES_LOADED=1
  [[ -n ${ZCODER_HOME:-} ]] || return 0
  local file="$ZCODER_HOME/ui-preferences" line=''
  [[ -f $file && ! -h $file && -r $file ]] || return 0
  # Treat the file as data: only literal, known values can change UI state.
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      sidebar_hidden=0) UI_SIDEBAR_HIDDEN=0 ;;
      sidebar_hidden=1) UI_SIDEBAR_HIDDEN=1 ;;
    esac
  done < "$file"
  return 0
}

ui_preferences_save() {
  emulate -L zsh
  [[ -n ${ZCODER_HOME:-} ]] || return 0
  local file="$ZCODER_HOME/ui-preferences" temporary fd=''
  [[ ! -h $file && ! -d $file ]] || return 1
  zf_mkdir -p -m 700 -- "$ZCODER_HOME" 2>/dev/null || return 1
  temporary="$file.${sysparams[pid]:-$$}.$RANDOM.tmp"
  sysopen -w -m 0600 -o creat,excl,nofollow,cloexec -u fd -- "$temporary" 2>/dev/null || return 1
  # Publish a complete file in one rename. Concurrent TUIs use the last explicit
  # change; merely exiting or resizing an older TUI never overwrites it.
  {
    print -r -u "$fd" -- "sidebar_hidden=$UI_SIDEBAR_HIDDEN" || return 1
    exec {fd}>&- || return 1
    fd=''
    zf_mv -f -- "$temporary" "$file" 2>/dev/null
  } always {
    [[ -n $fd ]] && exec {fd}>&-
    zf_rm -f -- "$temporary" 2>/dev/null
  }
}

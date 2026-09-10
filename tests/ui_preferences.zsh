() {
  local ZCODER_HOME="$TEST_TMP/ui preferences"
  local -i UI_SIDEBAR_HIDDEN=0 UI_PREFERENCES_LOADED=0
  local saved_move=${functions[zf_mv]-} value=''
  local -a scratch=()
  local -A file_info=()
  ui_preferences_load
  assert_eq 0 "$UI_SIDEBAR_HIDDEN" 'missing UI preferences keep the sidebar visible by default'
  [[ ! -e $ZCODER_HOME ]]
  assert_success 'loading default UI preferences does not create configuration files' $?
  UI_SIDEBAR_HIDDEN=1
  ui_preferences_save
  assert_success 'sidebar preferences save in a new configuration directory with spaces' $?
  assert_eq $'sidebar_hidden=1\n' "${mapfile[$ZCODER_HOME/ui-preferences]}" 'sidebar preferences contain literal data'
  zstat -H file_info "$ZCODER_HOME/ui-preferences"
  assert_eq 0 "$(( file_info[mode] & 077 ))" 'UI preferences are private to the user'

  UI_SIDEBAR_HIDDEN=0; UI_PREFERENCES_LOADED=0
  ui_preferences_load
  assert_eq 1 "$UI_SIDEBAR_HIDDEN" 'saved hidden preference is restored'
  mapfile[$ZCODER_HOME/ui-preferences]=$'sidebar_hidden=0\n'
  ui_preferences_load
  assert_eq 1 "$UI_SIDEBAR_HIDDEN" 'curses reentry does not import another TUI instance change'
  UI_PREFERENCES_LOADED=0
  ui_preferences_load
  assert_eq 0 "$UI_SIDEBAR_HIDDEN" 'a new launch restores the latest explicit visible preference'
  for value in 'sidebar_hidden=1+1' 'sidebar_hidden=$(print executed > "$ZCODER_HOME/executed")' 'unknown=1'; do
    mapfile[$ZCODER_HOME/ui-preferences]="$value"
    UI_PREFERENCES_LOADED=0
    ui_preferences_load
    assert_eq 0 "$UI_SIDEBAR_HIDDEN" 'invalid and unknown preference values are ignored as data'
  done
  [[ ! -e $ZCODER_HOME/executed ]]
  assert_success 'loading UI preferences never executes shell text' $?

  mapfile[$ZCODER_HOME/ui-preferences]=$'sidebar_hidden=1\n'
  zf_mv() { return 1; }
  {
    ui_preferences_save
    assert_failure 'failed preference publication reports failure' $?
    assert_eq $'sidebar_hidden=1\n' "${mapfile[$ZCODER_HOME/ui-preferences]}" 'failed publication preserves the previous preference'
    scratch=("$ZCODER_HOME"/*.tmp(N))
    assert_eq 0 "${#scratch}" 'failed publication removes its temporary file'
  } always {
    if [[ -n $saved_move ]]; then functions[zf_mv]=$saved_move; else unfunction zf_mv; fi
  }
}

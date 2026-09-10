# Exercise failures without curses or foreground I/O; the PTY cases below
# verify the actual terminal modes, retained resources, and signal behavior.
() {
  emulate -L zsh
  local -A saved=()
  local name
  for name in zcoder_curses zcoder_curses_features ui_init ui_destroy_windows ui_setup_windows ui_refresh_all ui_poll_resize ui_status_notice ui_plain_transcript _ui_copy_transcript state_save_session agent_context_discovery_cancel; do
    saved[$name]=${functions[$name]:-}
  done
  local -i UI_ACTIVE=1 UI_SUSPENDED=0 UI_MODAL_ACTIVE=0 SCREEN_H=24 SCREEN_W=80 UI_RESIZE_PENDING=0
  local -i TERMINAL_NATIVE_PASTE=0 TERMINAL_PASTE=0 TERMINAL_FRAME_ACTIVE=0 TERMINAL_SYNC_ENABLED=0
  local TERMINAL_FD='' TERMINAL_SYNC_STATE=disabled
  local -i supported=1 mock_suspend_result=0 mock_resume_result=0 mock_copy_result=0 mock_init_result=0 close_during_copy=0
  local -i inits=0 ends=0 suspends=0 resumes=0 copies=0 layouts=0 saves=0 cancellations=0
  local -i rows=24 columns=80
  local notice='' copied=''
  zcoder_curses_features() { reply=(); (( supported )) && reply=(suspend_resume); return 0; }
  zcoder_curses() {
    case $1 in
      suspend) (( suspends++ )); return "$mock_suspend_result" ;;
      resume) (( resumes++ )); return "$mock_resume_result" ;;
      end) (( ends++ )) ;;
      position) dimensions=(0 0 0 0 "$rows" "$columns") ;;
    esac
    return 0
  }
  ui_init() { (( inits++ )); (( mock_init_result )) && return "$mock_init_result"; UI_ACTIVE=1; return 0; }
  ui_destroy_windows() { return 0; }
  ui_setup_windows() { (( layouts++ )); SCREEN_H=$rows; SCREEN_W=$columns; return 0; }
  ui_refresh_all() { return 0; }
  ui_poll_resize() { return 0; }
  ui_status_notice() { notice=$2; }
  ui_plain_transcript() { REPLY=$'safe\e[31m transcript'; }
  state_save_session() { (( saves++ )); }
  agent_context_discovery_cancel() { (( cancellations++ )); }
  _ui_copy_transcript() { (( copies++ )); copied=$1; (( close_during_copy )) && ui_end; return "$mock_copy_result"; }
  {
    ui_copy_view
    assert_eq 1:0:1:1:0:0:0 "$UI_ACTIVE:$UI_SUSPENDED:$suspends:$resumes:$ends:$inits:$cancellations" 'copy view retains the native session and background discovery'
    assert_eq 1 "$saves" 'copy view saves the session before handing off the terminal'
    assert_not_contains "$copied" $'\e' 'copy view sanitizes the transcript before foreground output'
    assert_eq 0 "$layouts" 'unchanged native geometry keeps existing UI windows'
    rows=32; columns=100
    ui_copy_view
    assert_eq 1:32:100 "$layouts:$SCREEN_H:$SCREEN_W" 'native resume rebuilds layout after a terminal resize'
    mock_copy_result=130
    ui_copy_view
    assert_eq 130 "$?" 'copy interruption preserves its status after restoring the UI'
    assert_eq 1:0 "$UI_ACTIVE:$UI_SUSPENDED" 'interrupted copy view restores UI ownership'
    mock_copy_result=1
    ui_copy_view
    assert_eq 1 "$?" 'foreground read failure still restores the UI'
    assert_eq 4 "$resumes" 'each completed, interrupted, or failed foreground action resumes once'
    mock_suspend_result=1; copies=0; ends=0
    ui_copy_view
    assert_failure 'a runtime suspension refusal is reported' $?
    assert_eq 0:0:1 "$copies:$ends:$UI_ACTIVE" 'suspension refusal cannot tear down an active paste or start a second reader'
    mock_suspend_result=0; mock_copy_result=0; supported=0
    ui_copy_view
    assert_eq 1:1:1:0 "$ends:$inits:$UI_ACTIVE:$UI_SUSPENDED" 'unsupported handoff uses the stock teardown and rebuild path'
    supported=1; mock_resume_result=1; ends=0; inits=0
    ui_copy_view
    assert_eq 1:1:1:0 "$ends:$inits:$UI_ACTIVE:$UI_SUSPENDED" 'failed native resume recovers through a fresh session'
    assert_contains "$notice" 'rebuilt' 'native recovery reports that retained resources were rebuilt'
    mock_init_result=1
    ui_copy_view 2> "$TEST_TMP/handoff-failure"
    assert_failure 'unrecoverable UI restoration returns failure' $?
    assert_eq 0:0 "$UI_ACTIVE:$UI_SUSPENDED" 'failed recovery leaves neither active nor suspended UI ownership'
    UI_ACTIVE=1; mock_init_result=0; mock_resume_result=0; close_during_copy=1; resumes=0; inits=0
    ui_copy_view
    assert_eq 0:0:0:0 "$UI_ACTIVE:$UI_SUSPENDED:$resumes:$inits" 'exit cleanup during copy view never reopens the UI'
    exec {TERMINAL_FD}> "$TEST_TMP/handoff-protocol"
    TERMINAL_SYNC_ENABLED=1; TERMINAL_FRAME_ACTIVE=1
    zcoder_curses() { print -rn -u "$TERMINAL_FD" -- "<$1>"; [[ $1 != resume ]] || return "$mock_resume_result"; }
    terminal_suspend
    terminal_resume
    assert_eq $'\e[?2026l<suspend>\e[?2004l\e[?2026h<resume>\e[?2026l\e[?2004h' "${mapfile[$TEST_TMP/handoff-protocol]}" 'handoff balances synchronized frames and restores application-owned paste mode'
    mock_resume_result=1
    terminal_resume
    assert_eq 1 "$?" 'resume preserves presentation failure status'
    assert_eq 0 "$TERMINAL_FRAME_ACTIVE" 'failed resume releases synchronized frame ownership'
    assert_contains "${mapfile[$TEST_TMP/handoff-protocol]}" $'<resume>\e[?2026l' 'failed resume still closes its synchronized frame'
  } always {
    [[ -n $TERMINAL_FD ]] && exec {TERMINAL_FD}>&-
    for name in "${(@k)saved}"; do
      if [[ -n $saved[$name] ]]; then functions[$name]=$saved[$name]
      else unfunction "$name" 2>/dev/null
      fi
    done
  }
}

() {
  emulate -L zsh
  local -a modes=(stock) reply=()
  local mode action base output='' chunk='' native=0 expected='' pid=''
  local capabilities
  capabilities=$(zsh -dfc 'source "$1/lib/curses.zsh"; ZCODER_CURSES=auto zcoder_curses_load "$1" || exit; typeset -a reply; zcoder_curses_features; print -r -- ${reply[(Ie)suspend_resume]}' handoff "$PROJECT_DIR")
  [[ $capabilities == <1-> ]] && modes+=(auto)
  handoff_wait() {
    local -F deadline=$(( EPOCHREALTIME + 8 ))
    while (( EPOCHREALTIME < deadline )); do
      while zpty -r handoff-ui chunk 2>/dev/null; do output+=$chunk; done
      [[ ${mapfile[$base.$1]:-} == "$2"* ]] && return 0
      zselect -t 1
    done
    return 1
  }
  handoff_run() {
    trap - EXIT INT TERM
    exec zsh -df "$TEST_DIR/fixtures/handoff_ui.zsh" "$PROJECT_DIR" "$base" "$mode" "$action"
  }
  {
    for mode in "${modes[@]}"; do
      native=0; [[ $mode == auto ]] && native=1
      for action in enter interrupt resize eof terminate; do
        base="$TEST_TMP/handoff-$mode-$action"; output=''
        TERM=xterm-256color zpty -b handoff-ui handoff_run
        handoff_wait ready 1
        assert_success "$mode copy view reaches foreground input for $action" $?
        expected=0:2:1
        (( native )) && expected=0:1:1
        assert_eq "$expected" "${mapfile[$base.foreground]:-}" "$mode copy view releases UI ownership and restores shell terminal modes"
        case $action in
          enter|resize) zpty -w -n handoff-ui $'\n' ;;
          interrupt) zpty -w -n handoff-ui $'\x03' ;;
          eof) zpty -w -n handoff-ui $'\x04' ;;
          terminate)
            pid=${mapfile[$base.pid]:-}
            [[ $pid == <1-> ]] && kill -TERM "$pid"
            ;;
        esac
        if [[ $action != terminate ]]; then
          handoff_wait resumed 1
          assert_success "$mode copy view restores the UI after $action" $?
          expected=0; [[ $action == interrupt ]] && expected=130; [[ $action == eof ]] && expected=1
          assert_eq "$expected" "${mapfile[$base.result]:-}" "$mode copy view preserves the $action result"
          expected=2:1; (( native )) && expected=1:0
          assert_eq "$expected" "${mapfile[$base.lifecycle]:-}" "$mode uses the expected initialization and discovery cleanup path"
          expected=24:80; [[ $action == resize ]] && expected=32:100
          assert_eq "$expected" "${mapfile[$base.size]:-}" "$mode resume restores the correct window geometry"
          (( native )) && assert_eq 1 "${mapfile[$base.retained]:-}" 'native handoff retains an independent window and prepared row'
          zpty -w -n handoff-ui $'\e[200~ post\e[201~'
          handoff_wait pasted 'draft post'
          assert_success "$mode paste and draft editing work after $action" $?
        fi
        handoff_wait closed 0:0:1
        assert_success "$mode $action cleanup restores terminal modes without reopening the screen" $?
        if [[ $action == terminate ]]; then
          assert_eq 143 "${mapfile[$base.exit]:-}" 'termination during copy view preserves the exit signal status'
          assert_eq 1:0 "${mapfile[$base.close_lifecycle]:-}" 'termination never resumes or reinitializes the suspended UI'
        fi
        zpty -d handoff-ui 2>/dev/null
      done
    done
  } always {
    zpty -d handoff-ui 2>/dev/null
    unfunction handoff_wait handoff_run
  }
}

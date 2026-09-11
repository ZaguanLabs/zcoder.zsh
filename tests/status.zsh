UI_ACTIVE=1; UI_MODAL_ACTIVE=0; REMOTE_MODE=local; SCREEN_W=120; SCREEN_H=24; SIDE_W=25
UI_NOTICE_UNTIL=0; ZCODER_ANIMATE=true
AGENT_CONTEXT_WINDOW=1000; AGENT_ESTIMATED_TOKENS=420; GOAL_STATUS=active
ui_set_status Ready
ui_status_update
assert_contains "$UI_STATUS_DISPLAY" '~42% ctx' "wide headers show an explicitly estimated context percentage"
assert_contains "$UI_STATUS_DISPLAY" 'goal:active' "wide headers show actual goal state"
REMOTE_MODE=client
ui_status_update
assert_not_contains "$UI_STATUS_DISPLAY" 'ctx' "remote headers do not substitute local context counters"
assert_not_contains "$UI_STATUS_DISPLAY" 'goal:' "remote headers do not substitute local goal state"
REMOTE_MODE=local; SCREEN_W=60
ui_status_update
assert_eq Ready "$UI_STATUS_DISPLAY" "narrow headers preserve the foreground status"
ui_invalidate header; MOCK_ZCURSES_CALLS=(); ui_draw_header
assert_contains "${(F)MOCK_ZCURSES_CALLS}" '[ Ready ]' "a 60-column terminal still paints its status badge"

status_header_identity_test() {
  local ZCODER_NAME=zcoder.zsh ZCODER_VERSION=0.11.3
  local ZCODER_MODEL=kat-coder-2.5-dev-mtp-q4-128k OLLAMA_HOST=192.168.1.48:11434
  local ZCODER_WORKSPACE=/workspace/zcoder.zsh REMOTE_MODE=local
  local -i SCREEN_W=60
  local call='' header_text=''
  for SCREEN_W in 60 80 160; do
    ui_invalidate header; MOCK_ZCURSES_CALLS=(); ui_draw_header
    assert_contains "${(F)MOCK_ZCURSES_CALLS}" 'zcoder.zsh v0.11.3' "the ${SCREEN_W}-column header retains the application name and version"
    assert_contains "${(F)MOCK_ZCURSES_CALLS}" '[ Ready' "the ${SCREEN_W}-column header retains its status beside the identity"
  done
  for call in "${MOCK_ZCURSES_CALLS[@]}"; do
    [[ "$call" == 'string top_win '* ]] && header_text+="${call#string top_win }"
  done
  assert_contains "$header_text" "$ZCODER_MODEL @ $OLLAMA_HOST │ zcoder.zsh" "a wide local header includes model, host, and workspace"
  assert_contains "${(F)MOCK_ZCURSES_CALLS}" $'attr top_win -bold -dim bold cyan/black\nstring top_win ⚡ zcoder.zsh v0.11.3' "header branding restores the lightning icon and cyan name/version"
  assert_contains "${(F)MOCK_ZCURSES_CALLS}" $'attr top_win -bold -dim bold yellow/black\nstring top_win '"$ZCODER_MODEL" "the model name retains its distinct yellow styling"
  assert_contains "${(F)MOCK_ZCURSES_CALLS}" $'attr top_win -bold -dim dim white/black\nstring top_win  @ '"$OLLAMA_HOST" "host and workspace retain subdued white styling"
  REMOTE_MODE=client
  local REMOTE_SERVER_NAME=remote-fixture REMOTE_ENDPOINT=192.168.1.48:7337
  ui_invalidate header; MOCK_ZCURSES_CALLS=(); ui_draw_header
  assert_contains "${(F)MOCK_ZCURSES_CALLS}" 'zcoder.zsh v0.11.3' "remote headers retain the application name and version"
  assert_contains "${(F)MOCK_ZCURSES_CALLS}" 'remote-fixture@192.168.1.48:7337' "remote headers identify the connected server"
  SCREEN_W=40; ZCODER_MODEL='模型模型模型模型模型模型'
  ui_invalidate header; MOCK_ZCURSES_CALLS=(); ui_draw_header
  local -i identity_cells=0 badge_column=0 header_row=1
  for call in "${MOCK_ZCURSES_CALLS[@]}"; do
    if [[ "$call" == 'move top_win '* ]]; then
      local -a position=(${=call})
      header_row=$position[3]
    fi
    if [[ "$call" == 'string top_win '* && "$call" != 'string top_win [ '* ]] && (( header_row == 1 )); then
      header_text="${call#string top_win }"
      (( identity_cells += ${(m)#header_text} ))
    elif [[ "$call" == 'move top_win 1 '* ]]; then badge_column="${call##* }"
    fi
  done
  assert_success "wide header glyphs remain separated from the status on narrow terminals" $(( identity_cells + 2 < badge_column ? 0 : 1 ))
}
status_header_identity_test
unfunction status_header_identity_test

ui_append_message error $'Connection lost\nFull diagnostic remains in transcript.'
ui_set_status Error
ui_set_status Ready
ui_status_notice warning 'Less urgent warning'
ui_status_update
assert_eq 'Error: Connection lost' "$UI_STATUS_DISPLAY" "detailed errors outlive Ready and outrank generic statuses and warnings"
assert_contains "${UI_CONTENTS[-1]}" 'Full diagnostic' "the complete diagnostic remains in the transcript"
UI_NOTICE_UNTIL=0
ui_status_update
assert_eq Ready "$UI_STATUS_DISPLAY" "expired notices restore the current foreground status"
ui_set_status 'Goal paused'
ui_status_update
assert_eq 'Warning: Goal paused' "$UI_STATUS_DISPLAY" "warning semantics remain readable without color"
ui_set_status Ready
transcript_reset
ui_status_update
assert_eq Ready "$UI_STATUS_DISPLAY" "notices do not leak across transcript resets"

ui_set_status 'Thinking 1'
UI_STATUS_SINCE=$(( EPOCHREALTIME - 2.1 ))
ui_status_update
assert_contains "$UI_STATUS_DISPLAY" 'Thinking 1 2s' "activity shows phase elapsed time without inventing progress"
status_test_since="$UI_STATUS_SINCE"
ui_set_status 'Thinking 1'
assert_eq "$status_test_since" "$UI_STATUS_SINCE" "repeated remote activity events do not restart elapsed time"
ZCODER_ANIMATE=false
ui_status_update
assert_eq 'Thinking 1 2s' "$UI_STATUS_DISPLAY" "animation opt-out retains useful elapsed time"
ui_set_status Ready
ui_refresh_all
MOCK_ZCURSES_CALLS=()
ui_refresh_all; ui_refresh_all
assert_eq 0 "${#MOCK_ZCURSES_CALLS}" "idle status issues no curses writes on repeated refreshes"
UI_MODAL_ACTIVE=1
ui_set_status 'Thinking 2'
ui_refresh_all
assert_eq 0 "${#MOCK_ZCURSES_CALLS}" "activity changes cannot repaint under an active modal"
UI_MODAL_ACTIVE=0
ui_set_status $'remote\e[31m\runsafe'
ui_status_update
assert_not_contains "$UI_STATUS_DISPLAY" $'\e' "remote status text cannot inject terminal escapes"
assert_not_contains "$UI_STATUS_DISPLAY" $'\r' "remote status text cannot move the cursor"
ZCODER_ANIMATE=true

typeset -g status_pty_base="$TEST_TMP/status-pty" status_pty_output='' status_pty_chunk=''
status_pty_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 8.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r status-ui status_pty_chunk 2>/dev/null; do status_pty_output+="$status_pty_chunk"; done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1 2>/dev/null
  done
  return 1
}
status_pty_run() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/status_ui.zsh" "$PROJECT_DIR" "$status_pty_base"
}
TERM=xterm-256color zpty -b status-ui status_pty_run
assert_success "status fixture starts with real curses" $?
status_pty_wait "$status_pty_base.animated" 1
assert_success "the existing activity loop animates while awaiting input" $?
assert_contains "$status_pty_output" 'zcoder vtest' "real curses displays the application name and version in the header"
assert_contains "$status_pty_output" 'Git: main' "real curses displays the branch on a narrow terminal without a sidebar"
assert_eq '1:1' "${mapfile[$status_pty_base.underlay]:-}" "animation never repaints unchanged transcript or editor windows"
zpty -w -n status-ui draft
status_pty_wait "$status_pty_base.draft" draft
assert_success "typing remains responsive during status animation" $?
zpty -w -n status-ui $'\x07'
status_pty_wait "$status_pty_base.modal" 1
assert_success "an approval can take ownership during activity" $?
mapfile[$status_pty_base.notify]=1
status_pty_wait "$status_pty_base.notice" '1:1'
assert_success "an error during approval leaves the dialog open and its underlay untouched" $?
zpty -w -n status-ui n
status_pty_wait "$status_pty_base.answer" n
assert_success "status updates never change the user's approval decision" $?
status_pty_wait "$status_pty_base.visible" 'Error: Connection lost'
assert_success "closing the modal reveals the error above the current Ready status" $?
mapfile[$status_pty_base.expire]=1
status_pty_wait "$status_pty_base.visible" Ready
assert_success "the real event loop expires notices without a keystroke" $?
zpty -w -n status-ui $'\e'
status_pty_wait "$status_pty_base.done" 1
assert_success "status activity restores the terminal on cancellation" $?
zpty -d status-ui
unfunction status_pty_wait status_pty_run

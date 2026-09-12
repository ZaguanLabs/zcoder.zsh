# The parent suite supplies the curses recorder and real UI functions.
UI_ACTIVE=1; UI_MODAL_ACTIVE=0; UI_ACTIVITY_DEPTH=0
UI_FOCUS=input; SCREEN_H=40; SCREEN_W=120; SIDE_W=25
INPUT_H=3; TOP_H=3; FOOT_H=1
STATE_ENABLED=0
input_reset
transcript_reset
ui_append_message assistant "Initial answer" "Inspect this reasoning"
ui_invalidate
MOCK_ZCURSES_CALLS=()
ui_refresh_all
activity_refreshes=("${(@M)MOCK_ZCURSES_CALLS:#refresh *}")
assert_eq "1" "${#activity_refreshes}" "dirty windows share one physical refresh"
assert_eq 'refresh top_win side_win chat_win foot_win input_win' "${activity_refreshes[1]}" "batching restores the input cursor last"
MOCK_ZCURSES_CALLS=()
ui_refresh_all
assert_eq "0" "${#MOCK_ZCURSES_CALLS}" "unchanged frames issue no curses calls"

ui_set_status Thinking
ui_refresh_all
assert_contains "${(F)MOCK_ZCURSES_CALLS}" 'clear top_win' "status changes repaint the header"
assert_not_contains "${(F)MOCK_ZCURSES_CALLS}" 'clear chat_win' "status changes leave the transcript untouched"
assert_not_contains "${(F)MOCK_ZCURSES_CALLS}" 'clear input_win' "status changes restore the cursor without repainting the editor"
MOCK_ZCURSES_CALLS=()
ui_append_message assistant "A new answer"
ui_refresh_all
assert_contains "${(F)MOCK_ZCURSES_CALLS}" 'clear chat_win' "new messages repaint the transcript"
assert_not_contains "${(F)MOCK_ZCURSES_CALLS}" 'clear top_win' "new messages leave an unchanged header untouched"
assert_not_contains "${(F)MOCK_ZCURSES_CALLS}" 'clear side_win' "new messages leave the session sidebar untouched"
MOCK_ZCURSES_CALLS=()
ui_refresh_all
assert_eq "0" "${#MOCK_ZCURSES_CALLS}" "normalized transcript scrolling does not cause another redraw"
UI_CONTENTS[2]="Revised answer"; transcript_changed 2
ui_refresh_all
assert_contains "${(F)MOCK_ZCURSES_CALLS}" 'Revised answer' "in-place transcript changes invalidate their window"
MOCK_ZCURSES_CALLS=()
ui_refresh_all
assert_eq "0" "${#MOCK_ZCURSES_CALLS}" "consuming transcript invalidation leaves the next frame clean"

ui_editor_input x ''
assert_contains "${(F)MOCK_ZCURSES_CALLS}" 'clear input_win' "typing repaints the editor"
assert_not_contains "${(F)MOCK_ZCURSES_CALLS}" 'clear chat_win' "typing within a visual row leaves the transcript untouched"
MOCK_ZCURSES_CALLS=()
ui_invalidate
ui_refresh_all
assert_contains "${(F)MOCK_ZCURSES_CALLS}" 'clear chat_win' "explicit invalidation restores obscured windows"
MOCK_ZCURSES_CALLS=()
UI_MODAL_ACTIVE=1
ui_set_status Ready
ui_refresh_all
assert_eq "0" "${#MOCK_ZCURSES_CALLS}" "underlying updates cannot overwrite an active overlay"
UI_MODAL_ACTIVE=0
ui_refresh_all
assert_contains "${(F)MOCK_ZCURSES_CALLS}" 'clear top_win' "deferred status is rendered after the modal releases ownership"

input_reset
ui_activity_begin
ui_activity_input d ''
ui_activity_input r ''
ui_activity_input $'\r' ENTER
assert_eq "dr" "$INPUT_BUF" "Enter does not submit or discard a draft during activity"
assert_eq "" "$INPUT_SUBMITTED" "activity input cannot submit a second prompt"
ui_activity_input '' LEFT
ui_activity_input a ''
assert_eq "dar" "$INPUT_BUF" "activity editing honors the cursor"
ui_activity_input '' END
activity_paste=$'\e[200~first\nsecond\e[201~'
for activity_ch in "${(@s::)activity_paste}"; do ui_activity_input "$activity_ch" ''; done
assert_eq $'darfirst\nsecond' "$INPUT_BUF" "bracketed paste keeps embedded newlines during activity"
assert_eq normal "$INPUT_TERM_STATE" "activity paste returns the shared decoder to normal"
ui_activity_input $'\t' ''
assert_eq chat "$UI_FOCUS" "activity Tab focuses the transcript without switching sessions"
ui_activity_input '' HOME
ui_activity_input $'\r' ENTER
assert_eq "0" "${UI_BLOCK_OPEN[1]}" "activity Enter folds the selected transcript entry"
ui_activity_input $'\x12' ''
assert_eq "1" "${UI_REASONING_OPEN[1]}" "activity Ctrl+R inspects selected reasoning"
ui_activity_input $'\t' ''
activity_draft="$INPUT_BUF"
ui_activity_input $'\x10' ''
ui_activity_input $'\x0e' ''
assert_eq "$activity_draft" "$INPUT_BUF" "activity command shortcuts cannot contaminate the draft"
ui_activity_input $'\e' ''
ui_activity_input '' ''
assert_success "nonblocking polls allow an Escape prefix to finish" $?
UI_ACTIVITY_ESCAPE_AT=$(( EPOCHREALTIME - 0.1 ))
ui_activity_input '' ''
assert_eq "130" "$?" "a bare Escape cancels after the sequence deadline"
assert_eq normal "$INPUT_TERM_STATE" "cancellation clears its decoder state"
ui_activity_end
assert_eq "0" "$UI_ACTIVITY_DEPTH" "activity completion releases input ownership"
assert_eq "$activity_draft" "$INPUT_BUF" "activity completion preserves the edited draft"

# Exercise each wait adapter and its cleanup without network/worker timing.
functions[_activity_saved_poll]="${functions[ui_poll_activity]}"
functions[_activity_saved_http_ready]="${functions[http_async_ready]}"
functions[_activity_saved_delegate_ready]="${functions[delegate_async_ready]}"
functions[_activity_saved_delegate_expired]="${functions[delegate_async_timed_out]}"
typeset -gi ACTIVITY_POLLS=0 ACTIVITY_POLL_RESULT=0 ACTIVITY_EXPIRED=0
ui_poll_activity() { (( ACTIVITY_POLLS++ )); return "$ACTIVITY_POLL_RESULT"; }
http_async_ready() { (( ACTIVITY_POLLS >= 2 )); }
delegate_async_ready() { (( ACTIVITY_POLLS >= 2 )); }
delegate_async_timed_out() { (( ACTIVITY_EXPIRED )); }
ui_wait_for_generation
assert_success "generation uses the shared activity poll until ready" $?
assert_eq "2" "$ACTIVITY_POLLS" "generation wait stops when its worker is ready"
ACTIVITY_POLLS=0; ACTIVITY_POLL_RESULT=130
ui_wait_for_delegate
assert_eq "130" "$?" "delegate waits preserve cancellation status"
assert_eq "0" "$UI_ACTIVITY_DEPTH" "cancelled waits release activity ownership"
ACTIVITY_POLLS=0; ACTIVITY_POLL_RESULT=0; ACTIVITY_EXPIRED=1
ui_wait_for_delegate
assert_eq "124" "$?" "delegate timeouts retain their distinct status"
assert_eq "0" "$ACTIVITY_POLLS" "expired delegates do not block for input"
assert_eq "0" "$UI_ACTIVITY_DEPTH" "timed-out waits release activity ownership"
ACTIVITY_POLL_RESULT=130
ui_poll_remote_turn
assert_eq "130" "$?" "remote input uses the same cancellation result"
functions[ui_poll_activity]="${functions[_activity_saved_poll]}"
functions[http_async_ready]="${functions[_activity_saved_http_ready]}"
functions[delegate_async_ready]="${functions[_activity_saved_delegate_ready]}"
functions[delegate_async_timed_out]="${functions[_activity_saved_delegate_expired]}"
unfunction _activity_saved_poll _activity_saved_http_ready _activity_saved_delegate_ready _activity_saved_delegate_expired

# Continuous remote events must not postpone input until a `none` response.
functions[_activity_saved_request]="${functions[remote_client_request]}"
functions[_activity_saved_ensure]="${functions[remote_client_model_ensure]}"
functions[_activity_saved_remote_poll]="${functions[ui_poll_remote_turn]}"
typeset -gi ACTIVITY_REMOTE_POLLS=0 ACTIVITY_REMOTE_EVENTS=0 ACTIVITY_REMOTE_CANCELS=0
typeset -ga ACTIVITY_REMOTE_DELAYS=()
remote_client_model_ensure() { return 0; }
remote_client_request() {
  case "$2" in
    /v1/events\?*)
      (( ACTIVITY_REMOTE_EVENTS++ ))
      HTTP_BODY="{\"event\":\"status\",\"seq\":${ACTIVITY_REMOTE_EVENTS},\"status\":\"Thinking\"}"
      ;;
    /v1/cancel) (( ACTIVITY_REMOTE_CANCELS++ )) ;;
  esac
  return 0
}
ui_poll_remote_turn() {
  ACTIVITY_REMOTE_DELAYS+=("${1:-50}")
  (( ACTIVITY_REMOTE_POLLS++ ))
  (( ACTIVITY_REMOTE_POLLS == 3 )) && return 130
  return 0
}
remote_client_user_turn 'Continuous events'
assert_eq "130" "$?" "continuous remote activity remains cancellable between events"
assert_eq "2" "$ACTIVITY_REMOTE_EVENTS" "remote cancellation stops fetching further events"
assert_eq '0 0 0' "${(j: :)ACTIVITY_REMOTE_DELAYS}" "busy remote event polling never adds a blocking input delay"
assert_eq "1" "$ACTIVITY_REMOTE_CANCELS" "remote activity cancellation uses the existing cancel endpoint"
assert_eq "0" "$UI_ACTIVITY_DEPTH" "remote cancellation releases activity ownership"
functions[remote_client_request]="${functions[_activity_saved_request]}"
functions[remote_client_model_ensure]="${functions[_activity_saved_ensure]}"
functions[ui_poll_remote_turn]="${functions[_activity_saved_remote_poll]}"
unfunction _activity_saved_request _activity_saved_ensure _activity_saved_remote_poll

test_integration activity || return 0

# Drive real curses waits with file barriers instead of model/network timing.
typeset -g activity_pty_base="$TEST_TMP/activity-pty" activity_pty_output="" activity_pty_chunk=""
activity_pty_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 5.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r activity-ui activity_pty_chunk 2>/dev/null; do
      activity_pty_output+="$activity_pty_chunk"
    done
    [[ "${mapfile[$file]:-}" == "$expected" ]] && return 0
    zselect -t 1 2>/dev/null
  done
  return 1
}
activity_pty_run() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/activity_ui.zsh" "$PROJECT_DIR" "$activity_pty_base"
}
TERM=xterm-256color zpty -b activity-ui activity_pty_run
assert_success "real curses activity fixture starts in a PTY" $?
activity_pty_wait "$activity_pty_base.state" 'input:0:1:80:1'
assert_success "real generation wait admits input while its worker is pending" $?
activity_before_paints="${mapfile[$activity_pty_base.paints]}"
activity_before_counts=("${(@s.:.)activity_before_paints}")
mapfile[$activity_pty_base.status]=1
activity_pty_wait "$activity_pty_base.status_done" 1
assert_success "real pending generation accepts a status update" $?
assert_eq "$(( activity_before_counts[1] + 1 )):${activity_before_counts[2]}:${activity_before_counts[3]}" "${mapfile[$activity_pty_base.paints]}" "a real status update repaints only the header"
zpty -w -n activity-ui next
activity_pty_wait "$activity_pty_base.draft" next
assert_success "real generation input retains a typed draft" $?
zpty -w -n activity-ui $'\r\e[200~one\ntwo\e[201~'
activity_pty_wait "$activity_pty_base.draft" $'nextone\ntwo'
assert_success "real Enter and bracketed paste preserve a multiline draft without submitting it" $?
zpty -w -n activity-ui $'\t\eOH\r'
activity_pty_wait "$activity_pty_base.state" 'chat:1:0:80:1'
assert_success "real generation input selects and folds a transcript entry" $?
activity_pty_tty="${mapfile[$activity_pty_base.tty]:-}"
if [[ -n "$activity_pty_tty" && -c "$activity_pty_tty" ]]; then
  command stty cols 60 rows 18 < "$activity_pty_tty"
fi
activity_pty_wait "$activity_pty_base.state" 'chat:1:0:60:1'
assert_success "real activity resize preserves transcript focus and folding" $?
zpty -w -n activity-ui $'\t'
activity_pty_wait "$activity_pty_base.state" 'input:1:0:60:1'
assert_success "real activity Tab returns to the pending draft" $?
mapfile[$activity_pty_base.release]=1
activity_pty_wait "$activity_pty_base.completed" '0:0'
assert_success "real worker completion releases generation input ownership" $?
assert_eq $'nextone\ntwo' "${mapfile[$activity_pty_base.draft]}" "real completion preserves the unsent multiline draft"
activity_pty_wait "$activity_pty_base.phase" delegate
assert_success "real delegate wait takes over through the shared activity loop" $?
zpty -w -n activity-ui $'\e'
activity_pty_wait "$activity_pty_base.cancelled" '130:0'
assert_success "real Escape cancels the delegate and releases input ownership" $?
activity_pty_wait "$activity_pty_base.done" 1
activity_pty_exit_status=$?
assert_success "real activity fixture restores the terminal on exit" "$activity_pty_exit_status"
if (( activity_pty_exit_status )); then
  print -r -- "Activity PTY output tail: ${(V)activity_pty_output[-1000,-1]}"
fi
zpty -d activity-ui
unfunction activity_pty_wait activity_pty_run

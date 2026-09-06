# Protocol replies must never become editor input or an approval keystroke.
terminal_test_feed() {
  local terminal_test_byte=''
  for terminal_test_byte in "${(@s::)1}"; do terminal_filter_input "$terminal_test_byte" '' ''; done
}
for terminal_test_mode in 0 1 2 3 4 9; do
  TERMINAL_SEQUENCE=''; TERMINAL_INPUT_QUEUE=(); TERMINAL_SYNC_STATE=pending; TERMINAL_SYNC_ENABLED=0
  TERMINAL_QUERY_DEADLINE=$(( EPOCHREALTIME + 10 ))
  terminal_test_feed $'\e[?2026;'"${terminal_test_mode}"'$y'
  assert_eq 0 "${#TERMINAL_INPUT_QUEUE}" "mode ${terminal_test_mode} reply is consumed before UI dispatch"
  if [[ "$terminal_test_mode" == 1 || "$terminal_test_mode" == 2 ]]; then
    assert_eq 1 "$TERMINAL_SYNC_ENABLED" "mode ${terminal_test_mode} enables synchronization"
  else
    assert_eq 0 "$TERMINAL_SYNC_ENABLED" "mode ${terminal_test_mode} retains ordinary refreshes"
  fi
done
TERMINAL_SYNC_STATE=pending; TERMINAL_SYNC_ENABLED=0; TERMINAL_QUERY_DEADLINE=0
terminal_test_feed $'\e[?2026;2$y'
assert_eq 'no reply' "$TERMINAL_SYNC_STATE" "late support cannot enable synchronization after the deadline"
assert_eq 0 "${#TERMINAL_INPUT_QUEUE}" "late replies cannot approve a command"
TERMINAL_SYNC_STATE=disabled
terminal_test_feed $'\e[?2026;2$y'
assert_eq disabled "$TERMINAL_SYNC_STATE" "unsolicited replies respect the opt-out"
assert_eq 0 "${#TERMINAL_INPUT_QUEUE}" "unsolicited replies are still protocol input"

TERMINAL_SYNC_STATE=pending; TERMINAL_QUERY_DEADLINE=$(( EPOCHREALTIME + 10 ))
terminal_test_feed $'\e[?2026;'
terminal_filter_input '' RESIZE ''
assert_eq RESIZE "${TERMINAL_INPUT_QUEUE[2]}" "resize events pass through a fragmented reply"
TERMINAL_INPUT_QUEUE=()
terminal_filter_input '' DOWN ''
assert_eq DOWN "${TERMINAL_INPUT_QUEUE[2]}" "navigation keys pass through a fragmented reply"
TERMINAL_INPUT_QUEUE=()

terminal_filter_input '' '' ''
terminal_test_feed '2$y'
assert_eq supported "$TERMINAL_SYNC_STATE" "a fragmented reply survives resize and idle input"
assert_eq 0 "${#TERMINAL_INPUT_QUEUE}" "fragmented replies never leak their final y"

TERMINAL_SYNC_ENABLED=0
terminal_test_text=$'a\e[13;2u\e\r\e[200~literal\e[?2026;2$y\nnext\e[201~z'
terminal_test_feed "$terminal_test_text"
terminal_test_result=''
while (( ${#TERMINAL_INPUT_QUEUE} )); do
  terminal_test_result+="${TERMINAL_INPUT_QUEUE[1]}"
  TERMINAL_INPUT_QUEUE[1,3]=()
done
assert_eq "$terminal_test_text" "$terminal_test_result" "editing sequences and protocol lookalikes in paste survive unchanged"
assert_eq 0 "$TERMINAL_PASTE" "paste delimiters release protocol filtering"
terminal_filter_input $'\e' '' ''
TERMINAL_ESCAPE_AT=0
terminal_filter_input '' '' ''
assert_eq $'\e' "${TERMINAL_INPUT_QUEUE[1]}" "a bare Escape is released on an idle poll"
TERMINAL_INPUT_QUEUE=()


TERMINAL_SYNC_STATE=pending; TERMINAL_QUERY_DEADLINE=$(( EPOCHREALTIME + 10 ))
terminal_test_feed $'\e[?2026;'"${(pl:200::0:)}"
assert_success "unfinished CSI input stays bounded" $(( ${#TERMINAL_SEQUENCE} <= 64 ? 0 : 1 ))
terminal_test_feed '2$y'
assert_eq 0 "$TERMINAL_SYNC_ENABLED" "discarded overlong replies cannot establish support"
assert_eq 0 "${#TERMINAL_INPUT_QUEUE}" "discarded overlong replies cannot leak an approval key"
terminal_test_feed x
assert_eq x "${TERMINAL_INPUT_QUEUE[1]}" "ordinary input resumes after an overlong sequence"
TERMINAL_INPUT_QUEUE=()

# A failed curses update must still end the synchronized frame.
functions[_terminal_saved_curses]="${functions[zcurses]}"
zcurses() { print -rn -u "$TERMINAL_FD" -- FRAME; return 7; }
exec {TERMINAL_FD}> "$TEST_TMP/terminal-frame"
TERMINAL_SYNC_ENABLED=1
terminal_refresh overlay_win
assert_eq 7 "$?" "synchronized refresh preserves curses failure status"
assert_eq $'\e[?2026hFRAME\e[?2026l' "${mapfile[$TEST_TMP/terminal-frame]}" "failed refreshes still emit a balanced frame"
assert_eq 0 "$TERMINAL_FRAME_ACTIVE" "failed refreshes release frame ownership"
terminal_end
assert_eq '' "$TERMINAL_FD" "terminal cleanup closes its output descriptor"
functions[zcurses]="${functions[_terminal_saved_curses]}"
unfunction _terminal_saved_curses

typeset -g terminal_pty_base="$TEST_TMP/terminal-pty" terminal_pty_output='' terminal_pty_chunk=''
terminal_pty_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 8.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r terminal-ui terminal_pty_chunk 2>/dev/null; do terminal_pty_output+="$terminal_pty_chunk"; done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1 2>/dev/null
  done
  return 1
}
terminal_pty_run() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/terminal_ui.zsh" "$PROJECT_DIR" "$terminal_pty_base"
}
TERM=xterm-256color zpty -b terminal-ui terminal_pty_run
assert_success "terminal capability fixture starts in real curses" $?
terminal_pty_wait "$terminal_pty_base.approval" '0:pending'
assert_success "approval is active while asynchronous terminal detection is pending" $?
assert_contains "$terminal_pty_output" $'\e[?2026$p' "auto mode emits the capability query"
assert_not_contains "$terminal_pty_output" $'\e[?2026h' "unknown support does not start synchronized frames"
zpty -w -n terminal-ui $'\e[?2026;2$y'
terminal_pty_wait "$terminal_pty_base.approval" '0:supported'
assert_success "a real terminal reply enables synchronization without approving or dismissing the dialog" $?
zpty -w -n terminal-ui n
terminal_pty_wait "$terminal_pty_base.answer" n
assert_success "only the user's explicit denial completes the approval" $?
zpty -w -n terminal-ui $'draft\e[200~line1\nline2\e[201~'
terminal_pty_wait "$terminal_pty_base.draft" $'draftline1\nline2'
assert_success "real curses preserves multiline paste after capability detection" $?
assert_contains "$terminal_pty_output" $'\e[?2026h' "supported terminals wrap subsequent curses output"
assert_contains "$terminal_pty_output" $'\e[?2026l' "synchronized frames end before input waits"
zpty -w -n terminal-ui $'\x07'
terminal_pty_wait "$terminal_pty_base.diagnostics" 1
assert_success "terminal diagnostics opens after background activity" $?
zpty -w -n terminal-ui $'\e'
terminal_pty_wait "$terminal_pty_base.done" 1
assert_success "diagnostics closes and terminal lifecycle reentry completes" $?
assert_contains "$terminal_pty_output" 'Terminal diagnostics' "terminal inspection renders a real modal"
assert_eq ':0:0' "${mapfile[$terminal_pty_base.closed]:-}" "UI exit releases terminal descriptor and frame state"
assert_eq 'disabled:0' "${mapfile[$terminal_pty_base.false]:-}" "explicit opt-out survives UI reentry"
assert_eq 'forced:1' "${mapfile[$terminal_pty_base.true]:-}" "explicit support override enables synchronization"
assert_eq 'disabled (invalid setting):0' "${mapfile[$terminal_pty_base.invalid]:-}" "invalid configuration fails closed"
assert_eq 'no reply:0' "${mapfile[$terminal_pty_base.auto]:-}" "a silent terminal retains normal rendering"
assert_contains "$terminal_pty_output" $'\e[?2004l' "UI exit restores bracketed paste mode"
zpty -d terminal-ui
unfunction terminal_test_feed terminal_pty_wait terminal_pty_run

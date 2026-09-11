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

# A modal can disappear during a fragmented paste. Its remaining payload must
# still be drained before another owner receives deliberate keyboard input.
() {
  local -i TERMINAL_DISCARD_PASTE=1 TERMINAL_PASTE_DISCARDING=0 TERMINAL_PASTE=0
  local TERMINAL_SEQUENCE='' TERMINAL_PASTE_TAIL=''
  local -a TERMINAL_INPUT_QUEUE=()
  terminal_test_feed $'\e[200~y\ra\e'
  assert_eq 0 "${#TERMINAL_INPUT_QUEUE}" 'legacy modal paste hides its opening Escape and approval characters'
  terminal_filter_input '' DOWN ''
  terminal_filter_input '' ENTER ''
  assert_eq 0 "${#TERMINAL_INPUT_QUEUE}" 'decoded keys inside discarded paste cannot navigate or accept a modal'
  terminal_test_feed $'\e[20'
  terminal_filter_input '' DOWN ''
  terminal_test_feed '1~y'
  assert_eq 1:0 "$TERMINAL_PASTE:${#TERMINAL_INPUT_QUEUE}" 'decoded payload keys cannot splice fragments into a false paste terminator'
  terminal_filter_input '' RESIZE ''
  assert_eq ':RESIZE:' "${(j.:.)TERMINAL_INPUT_QUEUE}" 'resize remains available during discarded paste'
  TERMINAL_INPUT_QUEUE=()
  TERMINAL_DISCARD_PASTE=0
  terminal_test_feed "${(pl:4096::y:)}"
  assert_eq 0 "${#TERMINAL_INPUT_QUEUE}" 'closing a modal mid-paste cannot leak the rest into the editor'
  assert_eq 6 "${#TERMINAL_PASTE_TAIL}" 'discarded paste retains only a bounded delimiter tail'
  terminal_test_feed $'\e[20'
  terminal_filter_input '' '' ''
  terminal_test_feed $'1~n'
  assert_eq 'n::' "${(j.:.)TERMINAL_INPUT_QUEUE}" 'a split closing delimiter releases the next deliberate keystroke'
  assert_eq 0:0 "$TERMINAL_PASTE:$TERMINAL_PASTE_DISCARDING" 'completed legacy paste releases both stream flags'
}


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
functions[_terminal_saved_curses]="${functions[zcoder_curses]}"
zcoder_curses() { print -rn -u "$TERMINAL_FD" -- FRAME; return 7; }
exec {TERMINAL_FD}> "$TEST_TMP/terminal-frame"
TERMINAL_SYNC_ENABLED=1
terminal_refresh overlay_win
assert_eq 7 "$?" "synchronized refresh preserves curses failure status"
assert_eq $'\e[?2026hFRAME\e[?2026l' "${mapfile[$TEST_TMP/terminal-frame]}" "failed refreshes still emit a balanced frame"
assert_eq 0 "$TERMINAL_FRAME_ACTIVE" "failed refreshes release frame ownership"
terminal_end
assert_eq '' "$TERMINAL_FD" "terminal cleanup closes its output descriptor"
functions[zcoder_curses]="${functions[_terminal_saved_curses]}"
unfunction _terminal_saved_curses

# Exercise capability selection and record adaptation without terminal I/O.
() {
  local saved_curses=${functions[zcoder_curses]}
  local saved_features=${functions[zcoder_curses_features]}
  local -a features=() TERMINAL_EVENT_FLAGS=() TERMINAL_INPUT_QUEUE=()
  local -i TERMINAL_NOREFRESH_INPUT=0 discovery_result=0 read_result=0 calls=0 legacy_calls=0
  local TERMINAL_SEQUENCE='' TERMINAL_SYNC_STATE=disabled TERMINAL_PASTE_TAIL=''
  local -i TERMINAL_PASTE=0 TERMINAL_CSI_DISCARD=0
  local TERMINAL_FD='' ch='' key='' mouse='' call='' feature_set=''
  local -A record=(type character text 界)
  zcoder_curses_features() { reply=("${features[@]}"); return "$discovery_result"; }
  zcoder_curses() {
    (( calls++ )); call="${(j: :)@}"
    if [[ $1 == event ]]; then
      terminal_event=("${(@kv)record}")
      return "$read_result"
    fi
    (( legacy_calls++ )); terminal_byte=L; terminal_key=''; terminal_mouse=''
  }
  {
    for feature_set in '' structured_events norefresh_events; do
      features=("$feature_set")
      terminal_detect_input
      assert_eq 0 "$TERMINAL_NOREFRESH_INPUT" 'incomplete capabilities retain legacy input'
    done
    features=(structured_events norefresh_events)
    terminal_detect_input
    assert_eq '1:norefresh' "$TERMINAL_NOREFRESH_INPUT:${(j: :)TERMINAL_EVENT_FLAGS}" 'no-refresh input works without compiled mouse support'
    features+=(mouse)
    terminal_detect_input
    assert_eq 'norefresh mouse' "${(j: :)TERMINAL_EVENT_FLAGS}" 'supported mouse reporting stays enabled'
    terminal_read_event input_win ch key mouse
    assert_eq '界::' "$ch:$key:$mouse" 'structured Unicode reaches the character queue'
    assert_eq 'event input_win terminal_event norefresh mouse' "$call" 'input requests explicit presentation on the selected window'
    record=(type key key UP)
    terminal_read_event overlay_win ch key mouse
    assert_eq ':UP:' "$ch:$key:$mouse" 'structured navigation preserves the existing key contract'
    record=(type resize source terminal rows 40 columns 120)
    terminal_read_event input_win ch key mouse
    assert_eq ':RESIZE:' "$ch:$key:$mouse" 'synthetic resize reaches existing resize handling'
    record=(type mouse id 0 x 12 y 4 z 0 buttons 'PRESSED1 RELEASED1' modifiers 'SHIFT CTRL')
    terminal_read_event input_win ch key mouse
    assert_eq ':MOUSE:0 12 4 0 PRESSED1 RELEASED1 SHIFT CTRL' "$ch:$key:$mouse" 'mouse records preserve the legacy coordinates, buttons and modifiers'
    record=(type character text y); read_result=1; calls=0
    terminal_read_event input_win ch key mouse
    assert_eq ':::1:0' "$ch:$key:$mouse:$calls:$legacy_calls" 'failed reads discard record contents and never call a second reader'
    TERMINAL_SEQUENCE=$'\e'; TERMINAL_ESCAPE_AT=0
    terminal_read_event input_win ch key mouse
    assert_eq $'\e' "$ch" 'an idle structured read still releases a bare Escape'
    TERMINAL_INPUT_QUEUE=(queued '' ''); calls=0
    terminal_read_event input_win ch key mouse
    assert_eq queued:0 "$ch:$calls" 'queued filtered input is delivered without another module read'
    read_result=2; calls=0
    terminal_read_event input_win ch key mouse
    assert_eq 'L:0:2:1' "$ch:$TERMINAL_NOREFRESH_INPUT:$calls:$legacy_calls" 'unsupported flags switch to legacy with exactly one fallback read'
    assert_eq 0 "${#TERMINAL_EVENT_FLAGS}" 'unsupported event flags are cleared'
    calls=0
    terminal_read_event input_win ch key mouse
    assert_eq L:1:2 "$ch:$calls:$legacy_calls" 'later reads stay on the legacy path without probing'
    discovery_result=1
    terminal_detect_input
    assert_eq 0 "$TERMINAL_NOREFRESH_INPUT" 'unavailable discovery retains legacy input'
    discovery_result=0
    terminal_detect_input
    assert_eq 1 "$TERMINAL_NOREFRESH_INPUT" 'a new UI entry can select supported events again'
    terminal_end
    assert_eq 0:0 "$TERMINAL_NOREFRESH_INPUT:${#TERMINAL_EVENT_FLAGS}" 'terminal cleanup resets cached input capabilities'
  } always {
    functions[zcoder_curses]=$saved_curses
    functions[zcoder_curses_features]=$saved_features
  }
}

source "$TEST_DIR/native_sync.zsh"

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
  exec zsh -f "$TEST_DIR/fixtures/terminal_ui.zsh" "$PROJECT_DIR" "$terminal_pty_base" "$terminal_pty_mode"
}
typeset -a terminal_pty_modes=(stock)
terminal_input_features=$(zsh -dfc 'source "$1/lib/curses.zsh"; source "$1/lib/terminal.zsh"; ZCODER_CURSES=auto zcoder_curses_load "$1" || exit; terminal_detect_input; print -r -- "$TERMINAL_NOREFRESH_INPUT:$TERMINAL_CAN_PASTE:$TERMINAL_EVENT_POLL"' zcoder-test "$PROJECT_DIR")
terminal_has_norefresh=${terminal_input_features%%:*}
[[ $terminal_has_norefresh == 1 ]] && terminal_pty_modes+=(auto)
for terminal_pty_mode in "${terminal_pty_modes[@]}"; do
  terminal_pty_base="$TEST_TMP/terminal-pty-$terminal_pty_mode"
  terminal_pty_output=''
  TERM=xterm-256color zpty -b terminal-ui terminal_pty_run
  assert_success "terminal capability fixture starts in real curses" $?
  terminal_pty_wait "$terminal_pty_base.approval" '0:pending'
  assert_success "approval is active while asynchronous terminal detection is pending" $?
  terminal_expected_input=0
  [[ $terminal_pty_mode == auto ]] && terminal_expected_input=1
  assert_eq "$terminal_expected_input" "${mapfile[$terminal_pty_base.input]:-}" "$terminal_pty_mode selects its supported input presentation mode"
  assert_contains "$terminal_pty_output" $'\e[?2026$p' "auto mode emits the capability query"
  assert_not_contains "$terminal_pty_output" $'\e[?2026h' "unknown support does not start synchronized frames"
  zpty -w -n terminal-ui $'\e[?2026;2$y'
  terminal_pty_wait "$terminal_pty_base.approval" '0:supported'
  assert_success "a real terminal reply enables synchronization without approving or dismissing the dialog" $?
  terminal_native_paste=${mapfile[$terminal_pty_base.native]:-0:0}
  terminal_expected_native=0:0
  [[ $terminal_pty_mode == auto ]] && terminal_expected_native=${terminal_input_features#*:}
  assert_eq "$terminal_expected_native" "$terminal_native_paste" "$terminal_pty_mode activates only its available paste and polling capabilities"
  if [[ $terminal_native_paste == 1:* ]]; then
    zpty -w -n terminal-ui $'\e[200~y\r\x00\x03\e'
    terminal_pty_wait "$terminal_pty_base.approval_paste" 'PASTE_PENDING:0:4'
    assert_success 'native paste keeps control bytes and approval keys inside its payload' $?
    zpty -w -n terminal-ui $'\e[201~'
    terminal_pty_wait "$terminal_pty_base.approval_paste" 'PASTE:0:0'
    assert_success 'a completed native paste cannot answer the real approval dialog' $?
  else
    zpty -w -n terminal-ui $'\e[200~ya\rq\e'
    terminal_pty_wait "$terminal_pty_base.approval_legacy_paste" '1:1:0'
    assert_success 'stock paste keeps approval keys, Enter and Escape inside its payload' $?
    assert_eq 0 "$(( ${+mapfile[$terminal_pty_base.answer]} ))" 'an unfinished stock paste leaves the real approval open'
    zpty -w -n terminal-ui $'\e[201~'
    terminal_pty_wait "$terminal_pty_base.approval_legacy_paste" '0:0:0'
    assert_success 'a completed stock paste cannot answer or dismiss the real approval dialog' $?
  fi
  zpty -w -n terminal-ui n
  terminal_pty_wait "$terminal_pty_base.answer" n
  assert_success "only the user's explicit denial completes the approval" $?
  terminal_expected_sync=0:0
  # Older zdraw builds still exercise the legacy path.
  if [[ $terminal_pty_mode == auto ]]; then
    terminal_expected_sync=$(zsh -dfc 'source "$1/lib/curses.zsh"; source "$1/lib/terminal.zsh"; ZCODER_CURSES=auto zcoder_curses_load "$1" || exit; terminal_detect_input; print -r -- "$TERMINAL_CAN_SYNC:$TERMINAL_CAN_SYNC"' zcoder-test "$PROJECT_DIR")
  fi
  zpty -w -n terminal-ui $'draft\e[200~line1\nline2界e\u0301\e[201~'
  terminal_pty_wait "$terminal_pty_base.draft" $'draftline1\nline2界e\u0301'
  assert_success "real curses preserves Unicode multiline paste after capability detection" $?
  zpty -w -n terminal-ui $'\eOD\eOC!'
  terminal_pty_wait "$terminal_pty_base.draft" $'draftline1\nline2界e\u0301!'
  assert_success "decoded arrow keys remain navigation during activity" $?
  if [[ $terminal_native_paste == 1:* ]]; then
    zpty -w -n terminal-ui $'\e[200~\xc3'
    terminal_pty_wait "$terminal_pty_base.paste_bytes" 1
    assert_success 'native paste accepts a split UTF-8 prefix without freezing the activity loop' $?
    assert_eq $'draftline1\nline2界e\u0301!' "${mapfile[$terminal_pty_base.draft]}" 'an unfinished native paste leaves the draft unchanged'
    zpty -w -n terminal-ui $'\xa9\r'
    terminal_pty_wait "$terminal_pty_base.paste_bytes" 3
    assert_success 'native paste retains CR at a chunk boundary' $?
    zpty -w -n terminal-ui $'\nend\x00\x03\t\e[201~'
    terminal_pty_wait "$terminal_pty_base.draft" $'draftline1\nline2界e\u0301!é\nend    '
    assert_success 'native paste reconstructs split UTF-8 and CRLF while filtering raw controls' $?
    zpty -w -n terminal-ui $'\x03'
    terminal_pty_wait "$terminal_pty_base.control" cleared
    assert_success 'Ctrl-C outside native paste still clears the editor without killing the UI' $?
    assert_eq 'cleared:0:input::normal' "${mapfile[$terminal_pty_base.control]}" 'native raw input preserves application Ctrl-C handling'
  fi
  assert_contains "$terminal_pty_output" $'\e[?2026h' "supported terminals wrap subsequent curses output"
  assert_contains "$terminal_pty_output" $'\e[?2026l' "synchronized frames end before input waits"
  zpty -w -n terminal-ui $'\x07'
  terminal_pty_wait "$terminal_pty_base.diagnostics" 1
  assert_success "terminal diagnostics opens after background activity" $?
  assert_eq "$terminal_expected_sync" "${mapfile[$terminal_pty_base.sync]}" 'negotiated synchronization uses the selected backend'
  if [[ $terminal_expected_sync == 1:1 ]]; then
    assert_contains "${mapfile[$terminal_pty_base.diagnostic_lines]}" 'native stage/present' 'native frame ownership is visible in diagnostics'
    assert_contains "${mapfile[$terminal_pty_base.diagnostic_lines]}" 'Capability evidence' 'native diagnostics include passive terminal evidence'
    assert_contains "${mapfile[$terminal_pty_base.diagnostic_lines]}" 'Prepared rows / bytes:' 'native diagnostics include resource counts'
  fi
  zpty -w -n terminal-ui $'\e'
  if [[ $terminal_native_paste == 1:* ]]; then
    terminal_pty_wait "$terminal_pty_base.abandon" ready
    assert_success 'native paste can be enabled again after UI lifecycle reentry' $?
    zpty -w -n terminal-ui $'\e[200~unfinished'
  fi
  terminal_pty_wait "$terminal_pty_base.done" 1
  assert_success "diagnostics closes and terminal lifecycle reentry completes" $?
  assert_contains "$terminal_pty_output" 'Terminal diagnostics' "terminal inspection renders a real modal"
  assert_eq ':0:0' "${mapfile[$terminal_pty_base.closed]:-}" "UI exit releases terminal descriptor and frame state"
  assert_eq 'disabled:0' "${mapfile[$terminal_pty_base.false]:-}" "explicit opt-out survives UI reentry"
  assert_eq 'forced:1' "${mapfile[$terminal_pty_base.true]:-}" "explicit support override enables synchronization"
  assert_eq 'disabled (invalid setting):0' "${mapfile[$terminal_pty_base.invalid]:-}" "invalid configuration fails closed"
  assert_eq 'no reply:0' "${mapfile[$terminal_pty_base.auto]:-}" "a silent terminal retains normal rendering"
  assert_contains "$terminal_pty_output" $'\e[?2004l' "UI exit restores bracketed paste mode"
  assert_eq 1 "${mapfile[$terminal_pty_base.restored]:-}" 'UI teardown restores terminal modes even during an unfinished native paste'
  zpty -d terminal-ui
done
unfunction terminal_test_feed terminal_pty_wait terminal_pty_run

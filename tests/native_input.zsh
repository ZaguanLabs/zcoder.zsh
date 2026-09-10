# Native records keep paste payload out of the legacy character/key channel.
() {
  emulate -L zsh
  local saved_curses=$functions[zcoder_curses] saved_features=$functions[zcoder_curses_features]
  local -a TERMINAL_INPUT_QUEUE=() TERMINAL_EVENT_FLAGS=(norefresh) TERMINAL_PASTE_CHUNKS=()
  local -i TERMINAL_NATIVE_PASTE=1 TERMINAL_CAN_PASTE=1 TERMINAL_NOREFRESH_INPUT=1 TERMINAL_EVENT_POLL=1
  local -i TERMINAL_PASTE_BYTES=0 TERMINAL_PASTE_REJECTED=0 TERMINAL_PASTE_LIMIT=1048576
  local -i TERMINAL_PASTE=0 TERMINAL_CSI_DISCARD=0 calls=0 legacy_calls=0 read_result=0
  local TERMINAL_EVENT_TEXT='' TERMINAL_SEQUENCE='' TERMINAL_SYNC_STATE=disabled TERMINAL_PASTE_TAIL=''
  local ch='' key='' mouse='' request='' expected='' INPUT_EVENT_ACTION='' INPUT_EVENT_TEXT=''
  local INPUT_TERM_STATE=normal INPUT_ESCAPE_BUF=''
  local -A next_record=()
  zcoder_curses() {
    request="${(j: :)@}"; (( calls++ ))
    [[ $1 == input ]] && { (( legacy_calls++ )); return 0; }
    terminal_event=("${(@kv)next_record}")
    return "$read_result"
  }
  zcoder_curses_features() { reply=(structured_events norefresh_events streaming_paste event_poll input_info); }
  {
    terminal_detect_input
    assert_eq 1:1 "$TERMINAL_CAN_PASTE:$TERMINAL_EVENT_POLL" 'native input capabilities are discovered without starting protocols'
    next_record=(type paste phase begin text '')
    terminal_read_event input_win ch key mouse poll
    assert_eq ':PASTE_BEGIN:' "$ch:$key:$mouse" 'paste begin never exposes an editor or approval character'
    assert_contains "$request" 'norefresh poll' 'activity reads request polling without changing window timeouts'
    input_decode_terminal_event "$ch" "$key"
    assert_eq '' "$INPUT_EVENT_ACTION" 'paste begin cannot insert or submit text'
    next_record=(type paste phase data text $'y\r\n\xc3')
    terminal_read_event input_win ch key mouse poll
    assert_eq ':PASTE_PENDING:' "$ch:$key:$TERMINAL_EVENT_TEXT" 'partial UTF-8 and pasted approval keys stay private'
    next_record=(type paste phase end text $'\xa9\r\x00\x03\x1b\tend')
    terminal_read_event input_win ch key mouse poll
    assert_eq ':PASTE:' "$ch:$key:$mouse" 'completed paste uses a distinct event with an empty character field'
    assert_eq $'y\r\n\xc3\xa9\r\x00\x03\x1b\tend' "$TERMINAL_EVENT_TEXT" 'paste assembly includes final-record bytes without splitting UTF-8'
    local modal_ch=$ch modal_key=$key modal_result='' modal_done=0 modal_accepted=0 allow_session=1
    _ui_approval_input
    assert_eq 0:0: "$modal_done:$modal_accepted:$modal_result" 'pasted y and controls cannot approve, deny, or dismiss a command'
    input_decode_terminal_event "$ch" "$key"
    assert_eq paste "$INPUT_EVENT_ACTION" 'the editor recognizes the completed native paste'
    assert_eq $'y\né\n    end' "$INPUT_EVENT_TEXT" 'native paste normalizes CRLF, expands tabs, and strips terminal controls'
    assert_eq 0:0 "$TERMINAL_PASTE_BYTES:${#TERMINAL_PASTE_CHUNKS}" 'completed paste releases its bounded accumulator'
    next_record=(type character text x)
    terminal_read_event input_win ch key mouse
    assert_eq x:: "$ch:$key:$TERMINAL_EVENT_TEXT" 'the next ordinary event cannot replay a paste payload'

    TERMINAL_PASTE_LIMIT=4
    next_record=(type paste phase begin text '')
    terminal_read_event input_win ch key mouse
    next_record=(type paste phase data text 1234)
    terminal_read_event input_win ch key mouse
    next_record=(type paste phase data text 5)
    terminal_read_event input_win ch key mouse
    assert_eq 1:0 "$TERMINAL_PASTE_REJECTED:${#TERMINAL_PASTE_CHUNKS}" 'an oversized paste releases accumulated text and enters discard mode'
    next_record=(type paste phase end text y)
    terminal_read_event input_win ch key mouse
    assert_eq ':PASTE_REJECTED:' "$ch:$key:$TERMINAL_EVENT_TEXT" 'oversized paste drains its terminator without inserting a prefix or approval key'
    input_decode_terminal_event "$ch" "$key"
    assert_eq paste_rejected "$INPUT_EVENT_ACTION" 'the editor reports a rejected paste'
    next_record=(type paste phase begin text '')
    terminal_read_event input_win ch key mouse
    next_record=(type paste phase end text 1234)
    terminal_read_event input_win ch key mouse
    assert_eq PASTE:1234 "$key:$TERMINAL_EVENT_TEXT" 'a paste exactly at the byte limit succeeds after rejection'

    # Terminal replies can be fragmented around a native paste event. Preserve
    # the CSI filter's pending state so the eventual final y stays protocol data.
    TERMINAL_SEQUENCE=$'\e[?2026;'; TERMINAL_SYNC_STATE=pending
    local -F TERMINAL_QUERY_DEADLINE=$(( EPOCHREALTIME + 10 ))
    local -i TERMINAL_SYNC_ENABLED=0
    next_record=(type paste phase begin text '')
    terminal_read_event input_win ch key mouse
    next_record=(type paste phase end text y)
    terminal_read_event input_win ch key mouse
    assert_eq ':PASTE:y' "$ch:$key:$TERMINAL_EVENT_TEXT" 'paste remains separate while a capability reply is incomplete'
    for expected in 2 '$' y; do
      next_record=(type character text "$expected")
      terminal_read_event input_win ch key mouse
      assert_eq '::' "$ch:$key:$TERMINAL_EVENT_TEXT" 'a capability reply fragmented around paste cannot leak a keystroke'
    done
    assert_eq supported "$TERMINAL_SYNC_STATE" 'native paste preserves pending capability detection'

    read_result=2; calls=0
    terminal_read_event input_win ch key mouse poll
    assert_eq 1:0:1:0 "$TERMINAL_NOREFRESH_INPUT:$TERMINAL_EVENT_POLL:$calls:$legacy_calls" 'unsupported polling never falls back to a forbidden reader while native paste owns input'
    read_result=0; next_record=(type character text z)
    terminal_read_event input_win ch key mouse
    assert_eq z "$ch" 'structured input recovers on the next call without optional polling'
  } always {
    functions[zcoder_curses]=$saved_curses
    functions[zcoder_curses_features]=$saved_features
  }
}

# Batches must yield to the worker even with continuously queued keyboard input.
() {
  emulate -L zsh
  local saved_read=$functions[terminal_read_event] saved_wait=$functions[terminal_wait_input]
  local saved_activity=$functions[ui_activity_input] saved_resize=$functions[ui_poll_resize]
  local -i TERMINAL_EVENT_POLL=1 TERMINAL_INPUT_FD=0 TERMINAL_WAIT_MS=20
  local -i reads=0 handled=0 waits=0 queued=1 input_result=0
  local wait_args=''
  terminal_read_event() { (( reads++ )); ch=''; key=''; mouse=''; (( queued )) && ch=x; return 0; }
  terminal_wait_input() { (( waits++ )); }
  ui_activity_input() { (( handled++ )); return "$input_result"; }
  ui_poll_resize() { return 0; }
  {
    ui_poll_activity
    assert_eq 32:32:0 "$reads:$handled:$waits" 'continuous input yields to worker polling after a bounded batch'
    queued=0; reads=0; handled=0
    ui_poll_activity
    assert_eq 1:1:1 "$reads:$handled:$waits" 'an empty poll processes Escape deadlines and waits once instead of spinning'
    input_result=130
    ui_poll_activity
    assert_eq 130 "$?" 'cancellation exits a native input batch immediately'
    assert_eq 1 "$waits" 'cancelled activity never waits again'
    functions[terminal_wait_input]=$saved_wait
    zselect() { wait_args="${(j: :)@}"; return 1; }
    terminal_wait_input 50
    assert_eq '-r 0 -t 2' "$wait_args" 'idle activity waits only on terminal readiness for at most 20 ms'
    terminal_wait_input 0
    assert_eq '-r 0 -t 2' "$wait_args" 'zero-time activity requests do not introduce a sleep'
  } always {
    functions[terminal_read_event]=$saved_read
    functions[terminal_wait_input]=$saved_wait
    functions[ui_activity_input]=$saved_activity
    functions[ui_poll_resize]=$saved_resize
    unfunction zselect 2>/dev/null
  }
}

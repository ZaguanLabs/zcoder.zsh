# Native query and presentation ownership must survive failure and handoff.
() {
  local saved_curses=${functions[zcoder_curses]} saved_features=${functions[zcoder_curses_features]}
  local saved_write=${functions[_terminal_write]}
  local -a calls=() writes=() reply=() TERMINAL_INPUT_QUEUE=() TERMINAL_EVENT_FLAGS=()
  local -a features=(structured_events norefresh_events staged_refresh capability_queries synchronized_output suspend_resume)
  local -A record=()
  local -i TERMINAL_CAN_SYNC=0 TERMINAL_NATIVE_QUERY=0 TERMINAL_NATIVE_SYNC=0 TERMINAL_SYNC_ENABLED=0
  local -i TERMINAL_CAN_PASTE=0 TERMINAL_NATIVE_PASTE=0 TERMINAL_EVENT_POLL=0 TERMINAL_NOREFRESH_INPUT=0
  local -i TERMINAL_PASTE=0 TERMINAL_FRAME_ACTIVE=0
  local -i UI_ACTIVE=1 UI_MODAL_ACTIVE=0 SIDE_W=0
  local -A UI_PENDING_WINDOWS=()
  local -i stage_result=0 present_result=0 event_result=0 sync_result=0 query_result=0 query_on_result=0 suspend_result=0
  local TERMINAL_SYNC_STATE=inactive TERMINAL_SYNC_POLICY=auto TERMINAL_SEQUENCE='' TERMINAL_FD=''
  local ch='' key='' mouse='' mode=''
  zcoder_curses_features() { reply=("${features[@]}"); }
  _terminal_write() { writes+=("$1"); }
  zcoder_curses() {
    calls+=("${(j: :)@}")
    case "$1 $2" in
      'query on') return $query_on_result ;;
      'query request') return $query_result ;;
      'sync on') return $sync_result ;;
    esac
    case $1 in
      stage) return $stage_result ;;
      present) return $present_result ;;
      suspend) return $suspend_result ;;
      event) terminal_event=("${(@kv)record}"); return $event_result ;;
    esac
    return 0
  }
  {
    terminal_detect_input
    assert_eq 1 "$TERMINAL_CAN_SYNC" 'native sync requires staged drawing and no-refresh structured input'
    features=(structured_events norefresh_events capability_queries synchronized_output)
    terminal_detect_input
    assert_eq 0 "$TERMINAL_CAN_SYNC" 'missing staged presentation retains the legacy sync path'
    features+=(staged_refresh suspend_resume)
    terminal_detect_input
    for TERMINAL_SYNC_POLICY in false true invalid; do
      calls=(); writes=(); TERMINAL_SYNC_ENABLED=0
      _terminal_sync_start
      assert_eq 0:0 "${#calls}:${#writes}" "$TERMINAL_SYNC_POLICY policy enables no native protocol or query"
    done
    TERMINAL_SYNC_POLICY=auto; TERMINAL_SYNC_ENABLED=0; calls=(); writes=()
    _terminal_sync_start
    assert_eq 'query on|query request synchronized_output 1000' "${(j:|:)calls}" 'auto sends exactly one native query'
    assert_eq 1:0 "$TERMINAL_NATIVE_QUERY:${#writes}" 'native query owns reply decoding without shell output'

    for mode in 0 1 3 4; do
      TERMINAL_SYNC_STATE=pending; calls=()
      record=(type capability name synchronized_output phase reply report "$mode" text y)
      terminal_read_event input_win ch key mouse
      assert_eq 'unsupported:0:0:::' "$TERMINAL_SYNC_STATE:$TERMINAL_NATIVE_SYNC:$TERMINAL_SYNC_ENABLED:$ch:$key:$mouse" "native report $mode cannot activate synchronization or approve a command"
      assert_eq 1 "${#calls}" 'non-reset evidence never calls sync on'
    done
    TERMINAL_SYNC_STATE=pending; record=(type capability name synchronized_output phase late report 2)
    terminal_read_event input_win ch key mouse
    assert_eq pending:0 "$TERMINAL_SYNC_STATE:$TERMINAL_SYNC_ENABLED" 'late structured replies cannot activate synchronization'
    terminal_test_feed $'\e[?2026;2$y'
    assert_eq pending:0 "$TERMINAL_SYNC_STATE:$TERMINAL_SYNC_ENABLED" 'fragmented raw replies cannot bypass native activation evidence'
    record[phase]=timeout
    terminal_read_event input_win ch key mouse
    assert_eq 'no reply:1' "$TERMINAL_SYNC_STATE:$TERMINAL_NATIVE_QUERY" 'native timeout retains decoding to consume later replies'
    record[phase]=reply
    terminal_read_event input_win ch key mouse
    assert_eq 'no reply:0' "$TERMINAL_SYNC_STATE:$TERMINAL_SYNC_ENABLED" 'completed queries cannot accept a later reply'

    TERMINAL_SYNC_STATE=pending; sync_result=1
    terminal_read_event input_win ch key mouse
    assert_eq unavailable:0:0 "$TERMINAL_SYNC_STATE:$TERMINAL_NATIVE_SYNC:$TERMINAL_SYNC_ENABLED" 'failed native activation never falls back to forced markers'
    TERMINAL_SYNC_STATE=pending; sync_result=0
    terminal_read_event input_win ch key mouse
    assert_eq supported:1:1 "$TERMINAL_SYNC_STATE:$TERMINAL_NATIVE_SYNC:$TERMINAL_SYNC_ENABLED" 'accepted reset evidence activates native synchronization'

    calls=(); writes=()
    terminal_refresh chat_win input_win
    assert_eq 'stage chat_win input_win|present' "${(j:|:)calls}" 'one batch stages in cursor order and presents exactly once'
    assert_eq 0 "${#writes}" 'native frames never get a second set of shell markers'
    stage_result=7; calls=()
    terminal_refresh overlay_win
    assert_eq 7 "$?" 'staging errors reach the caller'
    assert_eq 'stage overlay_win' "${(j:|:)calls}" 'failed staging cannot present a partial batch'
    stage_result=0; present_result=9; calls=()
    terminal_refresh overlay_win
    assert_eq 9 "$?" 'native presentation errors retain their status'
    assert_eq 'stage overlay_win|present' "${(j:|:)calls}" 'failed native presentation never retries through refresh'
    UI_PENDING_WINDOWS=(chat 1); calls=()
    ui_flush
    assert_eq 9 "$?" 'UI batches report failed presentation'
    assert_eq 1 "${UI_PENDING_WINDOWS[chat]:-0}" 'failed presentation retains the pending transcript for retry'
    present_result=0; calls=()
    ui_flush
    assert_eq 'stage chat_win input_win|present' "${(j:|:)calls}" 'a later flush retries the complete pending batch'
    assert_eq 0 "${#UI_PENDING_WINDOWS}" 'successful presentation clears the pending batch'
    calls=(); terminal_resume
    assert_eq resume "${(j:|:)calls}" 'native resume uses its own repaint boundary'

    TERMINAL_NATIVE_SYNC=0; TERMINAL_SYNC_ENABLED=0; TERMINAL_SYNC_STATE=pending
    suspend_result=1
    terminal_suspend
    assert_eq pending "$TERMINAL_SYNC_STATE" 'failed handoff preserves the outstanding query'
    suspend_result=0
    terminal_suspend
    assert_eq cancelled "$TERMINAL_SYNC_STATE" 'successful native handoff cancels pending detection without retry'
    event_result=2; TERMINAL_EVENT_POLL=1; calls=()
    terminal_read_event input_win ch key mouse poll
    assert_eq 1:0:1 "$TERMINAL_NOREFRESH_INPUT:$TERMINAL_EVENT_POLL:${#calls}" 'query ownership forbids a fallback to the legacy input reader'

    TERMINAL_NATIVE_SYNC=1; calls=()
    terminal_end
    assert_eq 'sync off|query off' "${(j:|:)calls}" 'cleanup releases native frame and query ownership'
    assert_eq 0:0:0 "$TERMINAL_NATIVE_QUERY:$TERMINAL_NATIVE_SYNC:$TERMINAL_SYNC_ENABLED" 'cleanup clears native flags for reentry'
    TERMINAL_CAN_SYNC=1; TERMINAL_SYNC_POLICY=auto; query_result=1; calls=(); writes=()
    _terminal_sync_start
    assert_eq unavailable:1:0 "$TERMINAL_SYNC_STATE:$TERMINAL_NATIVE_QUERY:${#writes}" 'failed query request retains decoding and never sends a second raw request'
    terminal_end
    TERMINAL_CAN_SYNC=1; query_on_result=1; calls=(); writes=()
    _terminal_sync_start
    assert_eq 'unavailable:0:0' "$TERMINAL_SYNC_STATE:$TERMINAL_NATIVE_QUERY:${#writes}" 'failed native query ownership cannot fall through to raw activation'
    assert_eq 'query on' "${(j:|:)calls}" 'query ownership failure sends no request'
  } always {
    functions[zcoder_curses]=$saved_curses
    functions[zcoder_curses_features]=$saved_features
    functions[_terminal_write]=$saved_write
  }
}

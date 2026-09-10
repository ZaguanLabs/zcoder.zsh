# Distinct processes may serialize their writes yet still hold different views
# of the same session. A successful lock acquisition is not ownership of history.
concurrency_state_tests() {
  local ZCODER_SESSIONS_DIR="$TEST_TMP/concurrent-sessions" CURRENT_SESSION_ID=9000000003_1
  local ZCODER_WORKSPACE="$TEST_TMP" ZCODER_PROFILE=coding SESSION_TITLE=Concurrent
  local STATE_SAVED_SESSION_ID='' STATE_SAVED_SNAPSHOT='' STATE_ERROR=''
  local STATE_OBSERVED_BASE='' STATE_OBSERVED_SNAPSHOT=''
  local -i STATE_ENABLED=1 STATE_LOADING=0 UI_PERSIST_DIRTY_FROM=0 AGENT_COMPACTION_COUNT=0
  local -a AGENT_MESSAGES=(original) AGENT_USER_MESSAGES=(request) SKILL_ACTIVE_NAMES=()
  local -a UI_ROLES=() UI_CONTENTS=() UI_THINKINGS=() UI_TIMES=() UI_REASONING_OPEN=() UI_IDS=()
  local base="$ZCODER_SESSIONS_DIR/$CURRENT_SESSION_ID.session" winner='' observed=''
  state_save_session
  assert_success 'concurrent-save fixture commits the shared starting history' $?
  observed=$STATE_SAVED_SNAPSHOT
  (
    trap - EXIT INT TERM HUP
    AGENT_MESSAGES+=(writer_a)
    state_save_session
  )
  assert_success 'another process commits while the first retains its old history' $?
  state_snapshot_dir "$base"; winner=$REPLY
  AGENT_MESSAGES+=(writer_b)
  state_save_session 2>/dev/null
  assert_failure 'a stale writer cannot replace a newer committed session' $?
  assert_contains "$STATE_ERROR" 'changed by another process' 'conflicting saves report why history was not published'
  state_snapshot_dir "$base"
  assert_eq "$winner" "$REPLY" 'the winning commit remains current after a conflicting save'
  assert_eq "$observed" "$STATE_SAVED_SNAPSHOT" 'rejected saves do not advance the stale writer cursor'
  assert_eq writer_b "$AGENT_MESSAGES[-1]" 'rejected saves retain unsaved in-memory work'
  state_saved_message_matches "$CURRENT_SESSION_ID" 2 writer_a 2
  assert_success 'the other process response remains readable after a stale save attempt' $?
  # Explicitly reload before applying a new change to the latest history.
  STATE_ENABLED=0
  state_load_session "$CURRENT_SESSION_ID"
  assert_success 'an explicit reload can recover from a save conflict' $?
  STATE_ENABLED=1
  AGENT_MESSAGES+=(after_reload)
  state_save_session
  assert_success 'a writer can save again after reloading the winning generation' $?
  state_saved_message_matches "$CURRENT_SESSION_ID" 3 after_reload 3
  assert_success 'saving after reload extends the newer history' $?
  SKILL_ACTIVE_NAMES=(concurrency_missing_skill)
  state_save_session
  STATE_ENABLED=0
  state_load_session "$CURRENT_SESSION_ID"
  assert_success 'a session can load when a previously active skill is unavailable' $?
  assert_eq '' "$STATE_SAVED_SESSION_ID" 'a missing skill invalidates the append cache'
  STATE_ENABLED=1
  (
    trap - EXIT INT TERM HUP
    AGENT_MESSAGES+=(writer_c)
    state_save_session
  )
  assert_success 'another process can commit after a lossy load' $?
  state_snapshot_dir "$base"; winner=$REPLY
  AGENT_MESSAGES+=(writer_d)
  state_save_session 2>/dev/null
  assert_failure 'invalidating an append cache cannot bypass stale-writer protection' $?
  state_snapshot_dir "$base"
  assert_eq "$winner" "$REPLY" 'a stale lossy load cannot replace the winning generation'
}
concurrency_state_tests
unfunction concurrency_state_tests

concurrency_cancel_tests() {
  local REMOTE_RUNTIME_DIR="$TEST_TMP/concurrent-cancel" REMOTE_SESSION_ID=9000000003_2 REMOTE_TURN_ID=new_turn
  local CURRENT_SESSION_ID=$REMOTE_SESSION_ID REMOTE_INPUT_TURN_ID=old_turn REMOTE_TOKEN=fixture
  local REMOTE_REQUEST_AUTHORIZATION='Bearer fixture' REMOTE_REQUEST_METHOD=POST REMOTE_REQUEST_TARGET=/v1/cancel
  local REMOTE_REQUEST_BODY='' HTTP_BODY='' sent_body='' response='' name='' request=''
  local -i response_code=0 queue_closes=0
  local -A saved=()
  for name in _remote_http_read_request _remote_server_reap_worker _remote_http_send _remote_http_error input_queue_close remote_server_emit_status _remote_server_publish_json remote_client_request agent_emit agent_set_status transcript_interrupt_tool; do
    saved[$name]=${functions[$name]:-}
  done
  _remote_http_read_request() { return 0; }
  _remote_server_reap_worker() { return 0; }
  _remote_http_send() { response_code=$2; response=$3; }
  _remote_http_error() { response_code=$2; response=$3; }
  input_queue_close() { (( queue_closes++ )); return 0; }
  remote_server_emit_status() { return 0; }
  _remote_server_publish_json() { return 0; }
  remote_client_request() { sent_body=$3; HTTP_BODY='{"ok":true}'; return 0; }
  agent_emit() { return 0; }
  agent_set_status() { return 0; }
  transcript_interrupt_tool() { return 0; }
  zf_mkdir -p "$REMOTE_RUNTIME_DIR"
  {
    for request in '{"session_id":"9000000003_2","turn_id":"old_turn"}' '{"session_id":"9000000003_9","turn_id":"new_turn"}'; do
      mapfile[$REMOTE_RUNTIME_DIR/pending_prompt]='new work'
      REMOTE_REQUEST_BODY=$request; queue_closes=0
      _remote_server_handle_connection 99
      assert_eq 409 "$response_code" 'a delayed cancellation cannot target a different session or turn'
      assert_eq 'new work' "${mapfile[$REMOTE_RUNTIME_DIR/pending_prompt]:-}" 'stale cancellation leaves the newer pending prompt intact'
      assert_eq 0 "$queue_closes" 'stale cancellation does not close newer input admission'
    done
    for request in '{"turn_id":"new_turn"}' '{"session_id":"9000000003_2","turn_id":null}' '{"turn":"old_turn"}' 'not JSON'; do
      mapfile[$REMOTE_RUNTIME_DIR/pending_prompt]='new work'
      REMOTE_REQUEST_BODY=$request
      _remote_server_handle_connection 99
      assert_eq 400 "$response_code" 'malformed scoped cancellations are rejected before stopping work'
      assert_eq 'new work' "${mapfile[$REMOTE_RUNTIME_DIR/pending_prompt]:-}" 'malformed cancellation leaves the pending prompt intact'
    done
    for request in '{"session_id":"9000000003_2","turn_id":"new_turn"}' '{}'; do
      mapfile[$REMOTE_RUNTIME_DIR/pending_prompt]='new work'
      REMOTE_REQUEST_BODY=$request
      _remote_server_handle_connection 99
      assert_eq 200 "$response_code" 'matching and legacy unscoped cancellations remain supported'
      [[ ! -e $REMOTE_RUNTIME_DIR/pending_prompt ]]
      assert_success 'an accepted cancellation removes its pending prompt' $?
    done
    remote_client_cancel_turn
    json_parse_flat_object "$sent_body"
    assert_eq "$CURRENT_SESSION_ID" "${JSON_OBJECT[session_id]:-}" 'the client cancellation names its session'
    assert_eq old_turn "${JSON_OBJECT[turn_id]:-}" 'the client cancellation names the turn it received'
    REMOTE_INPUT_TURN_ID=''
    remote_client_cancel_turn
    assert_eq '{}' "$sent_body" 'cancellation before a turn receipt preserves legacy behavior'
  } always {
    for name in "${(@k)saved}"; do
      if [[ -n $saved[$name] ]]; then functions[$name]=$saved[$name]; else unfunction "$name" 2>/dev/null; fi
    done
  }
}
concurrency_cancel_tests
unfunction concurrency_cancel_tests

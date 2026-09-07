# Fault injection happens only below TEST_TMP; production state is untouched.
hardening_state_tests() {
  local ZCODER_SESSIONS_DIR="$TEST_TMP/transaction-sessions" CURRENT_SESSION_ID=9000000001_1
  local ZCODER_WORKSPACE="$TEST_TMP" ZCODER_PROFILE=coding SESSION_TITLE=Transaction
  local STATE_SAVED_SESSION_ID='' STATE_SAVED_SNAPSHOT='' STATE_ERROR=''
  local -i STATE_ENABLED=1 STATE_LOADING=0 UI_PERSIST_DIRTY_FROM=0
  local -i AGENT_COMPACTION_COUNT=0 STATE_SAVED_AGENT_COUNT=0
  local -a AGENT_MESSAGES=('original') AGENT_USER_MESSAGES=('request') SKILL_ACTIVE_NAMES=()
  local -a UI_ROLES=() UI_CONTENTS=() UI_THINKINGS=() UI_TIMES=() UI_REASONING_OPEN=() UI_IDS=()
  local base="$ZCODER_SESSIONS_DIR/$CURRENT_SESSION_ID.session" snapshot='' original_record='' stage=''
  local saved_writer="${functions[_state_write]}" saved_mv=''
  local -a reply=()
  {
    state_save_session
    assert_success 'session transaction commits an initial generation' $?
    state_snapshot_dir "$base"; snapshot="$REPLY"
    state_record_paths "$snapshot" agent_messages 1; original_record="$reply[1]"
    assert_eq original "${mapfile[$original_record]}" 'committed history contains the exact message'

    functions[_hardening_real_state_write]="$saved_writer"
    _state_write() {
      if [[ "$1" == */agent_messages/000002 ]]; then STATE_ERROR='injected record failure'; return 1; fi
      _hardening_real_state_write "$@"
    }
    AGENT_MESSAGES+=(second)
    state_save_session 2>/dev/null
    assert_failure 'a record write failure propagates through session saving' $?
    assert_eq 1 "$STATE_SAVED_AGENT_COUNT" 'failed writes cannot advance saved cursors'
    state_snapshot_dir "$base"
    assert_eq "$snapshot" "$REPLY" 'failed generation leaves the previous commit selected'
    functions[_state_write]="$saved_writer"
    state_save_session
    assert_success 'a later save retries previously failed records' $?
    state_saved_message_matches "$CURRENT_SESSION_ID" 2 second 2
    assert_success 'queue verification observes the retried committed record' $?
    state_snapshot_dir "$base"; snapshot="$REPLY"
    state_record_paths "$snapshot" agent_messages 2
    assert_eq "$original_record" "$reply[1]" 'append commits reuse immutable earlier records'

    # Fail publication, after all generation records have been written.
    _state_write() {
      [[ "$1" == */.current.* ]] && { STATE_ERROR='injected publication failure'; return 1; }
      _hardening_real_state_write "$@"
    }
    AGENT_MESSAGES=(compacted)
    (( AGENT_COMPACTION_COUNT++ ))
    state_save_session 2>/dev/null
    assert_failure 'compaction publication failure cannot report success' $?
    state_snapshot_dir "$base"
    assert_eq "$snapshot" "$REPLY" 'failed compaction keeps the complete previous history'
    assert_eq original "${mapfile[$original_record]}" 'compaction never overwrites a committed record'
    functions[_state_write]="$saved_writer"

    # SIGKILL bypasses always cleanup and leaves a complete but unpublished
    # generation. The next reader must still see the old committed snapshot.
    (
      trap - EXIT INT TERM HUP
      _state_write() {
        [[ "$1" == */.current.* ]] && kill -KILL "$sysparams[pid]"
        _hardening_real_state_write "$@"
      }
      state_save_session
    ) 2>/dev/null
    assert_failure 'interrupted publication exits without a false success' $?
    state_snapshot_dir "$base"
    assert_eq "$snapshot" "$REPLY" 'reader ignores a generation abandoned by SIGKILL'
    state_save_session
    assert_success 'saving recovers after an abandoned generation' $?
    state_saved_message_matches "$CURRENT_SESSION_ID" 1 compacted 1
    assert_success 'recovered compaction publishes a coherent new history' $?

    # Legacy data stays readable and is preserved by first-save migration.
    CURRENT_SESSION_ID=9000000001_2
    base="$ZCODER_SESSIONS_DIR/$CURRENT_SESSION_ID.session"
    zf_mkdir -p "$base/agent_messages"
    mapfile[$base/workspace]="$TEST_TMP"; mapfile[$base/profile]=coding
    mapfile[$base/agent_message_count]=1; mapfile[$base/agent_messages/000001]=legacy
    STATE_ENABLED=0
    state_load_session "$CURRENT_SESSION_ID"
    assert_success 'legacy sessions load before migration' $?
    assert_eq legacy "$AGENT_MESSAGES[1]" 'legacy loading preserves original history'
    STATE_ENABLED=1
    state_save_session
    assert_success 'legacy history migrates through a committed generation' $?
    assert_eq legacy "${mapfile[$base/agent_messages/000001]}" 'migration retains legacy rollback data'
    state_saved_message_matches "$CURRENT_SESSION_ID" 1 legacy 1
    assert_success 'migrated history uses the same queue verification API' $?

    AGENT_MESSAGES+=(unsaved)
    state_load_session "$CURRENT_SESSION_ID"
    assert_success 'same-session reload first commits unsaved history' $?
    assert_eq unsaved "$AGENT_MESSAGES[-1]" 'same-session reload selects the new commit'
    (
      trap - EXIT INT TERM HUP
      zf_mv() {
        builtin zf_mv "$@" || return $?
        [[ "${@[-1]}" == "$base/current" ]] && kill -KILL "$sysparams[pid]"
        return 0
      }
      AGENT_MESSAGES+=(published)
      state_save_session
    ) 2>/dev/null
    assert_failure 'SIGKILL immediately after publication interrupts the writer' $?
    STATE_ENABLED=0
    state_load_session "$CURRENT_SESSION_ID"
    assert_success 'a reader accepts the complete commit published before SIGKILL' $?
    assert_eq published "$AGENT_MESSAGES[-1]" 'post-publication interruption preserves the new record'
    STATE_ENABLED=1
    local -i save_index
    for (( save_index=1; save_index<=35; save_index++ )); do
      AGENT_MESSAGES+=("append $save_index")
      state_save_session || break
    done
    assert_eq 36 "$save_index" 'repeated append commits survive generation collection'
    local -a manifests=("$base/generations/"*/previous(N))
    assert_success 'manifest retention is bounded between collections' $(( ${#manifests} <= 32 ? 0 : 1 ))
    STATE_ENABLED=0
    state_load_session "$CURRENT_SESSION_ID"
    assert_eq legacy "$AGENT_MESSAGES[1]" 'collection retains records shared from old generations'
    assert_eq 'append 35' "$AGENT_MESSAGES[-1]" 'collection preserves the newest complete history'
    state_snapshot_dir "$base"; snapshot="$REPLY"
    state_record_paths "$snapshot" agent_messages "${#AGENT_MESSAGES}"
    zf_rm -f -- "$reply[-1]"
    state_load_session "$CURRENT_SESSION_ID"
    assert_failure 'missing committed records are rejected without silently shortening history' $?
    assert_eq 'append 35' "$AGENT_MESSAGES[-1]" 'failed loading preserves the current in-memory history'
  } always {
    functions[_state_write]="$saved_writer"
    unfunction _hardening_real_state_write 2>/dev/null
  }
}
hardening_state_tests
unfunction hardening_state_tests

hardening_conversation_tests() {
  local -a AGENT_MESSAGES=('{"role":"system","content":"legacy"}' '{"role":"user","content":"queued","input_id":"receipt"}')
  local -a AGENT_USER_MESSAGES=(queued)
  local AGENT_SYSTEM_PROMPT=fixture AGENT_CONTEXT_TOOLS='[]' AGENT_COMPACTION_SUMMARY=''
  local -i GOAL_VERIFIER_ACTIVE=0
  json_parse_ollama_response '{"message":{"tool_calls":[{"function":{"name":"write_file","arguments":{"path":"a","content":"b"}}}]}} garbage'
  assert_failure 'a valid tool prefix does not make a malformed response executable' $?
  assert_eq 0 "${#JSON_TOOL_NAMES}" 'rejected response clears partial tool names'
  assert_eq '[]' "$JSON_RESPONSE_TOOL_CALLS" 'rejected response clears serialized tool calls'
  agent_build_compaction_payload
  assert_not_contains "$REPLY" '"role":"system","content":"legacy"' 'compaction normalizes legacy system messages'
  assert_not_contains "$REPLY" '"input_id"' 'compaction removes local queue receipts'
  assert_contains "$REPLY" '"role":"user","content":"legacy"' 'compaction preserves normalized history contents'

  local saved_parser="${functions[json_parse_ollama_response]}" saved_schema="${functions[agent_tools_schema_json]}"
  local -i parser_calls=0 schema_calls=0
  functions[_hardening_real_parser]="$saved_parser"
  json_parse_ollama_response() { (( parser_calls++ )); _hardening_real_parser "$@"; }
  agent_tools_schema_json() { (( schema_calls++ )); REPLY='[]'; }
  {
    AGENT_MESSAGES=('{"role":"assistant","content":"answer","thinking":"reason"}')
    agent_context_bill
    agent_context_bill
    assert_eq 1 "$parser_calls" 'unchanged reasoning is parsed once across repeated inspection'
    assert_eq 0 "$schema_calls" 'context inspection never discovers a tool catalog'
    AGENT_MESSAGES[1]='{"role":"assistant","content":"changed","thinking":"new reason"}'
    agent_context_bill
    assert_eq 2 "$parser_calls" 'same-length history replacement invalidates accounting metadata'
  } always {
    functions[json_parse_ollama_response]="$saved_parser"
    functions[agent_tools_schema_json]="$saved_schema"
    unfunction _hardening_real_parser
  }
}
hardening_conversation_tests
unfunction hardening_conversation_tests

# Document paths are request metadata; source text never enters a model payload.
document_context_tests() {
  local -i UI_ACTIVE=1 STATE_ENABLED=0 GOAL_VERIFIER_ACTIVE=0
  local -A UI_DOCUMENT_PATHS=(4 'docs/one file.md' 6 'docs/two.markdown')
  local -A UI_DOCUMENT_TEXTS=(4 'PRIVATE DOCUMENT CONTENT' 6 'SECOND PRIVATE CONTENT')
  local -A saved=() JSON_OBJECT=() JSON_OBJECT_TYPES=()
  local name='' snapshot='' captured='' captured_documents='' candidate=''
  local AGENT_SYSTEM_PROMPT=fixture AGENT_TOOL_PHASE=full
  local REMOTE_MODE=local REMOTE_DOCUMENT_CONTEXT_SUPPORTED=true REMOTE_INPUT_SUPPORTED=true
  local REMOTE_ERROR='' HTTP_BODY='' REMOTE_MODEL_STATUS=ready REMOTE_TURN_ID=''
  local REMOTE_RUNTIME_DIR="$TEST_TMP/document-context-runtime" REMOTE_SESSION_ID=fixture
  local REMOTE_REQUEST_METHOD=POST REMOTE_REQUEST_TARGET=/v1/turn REMOTE_REQUEST_BODY=''
  local -i response_status=0 REMOTE_REQUEST_CANCELLED=0
  local -a AGENT_MESSAGES=() reply=()
  for name in _agent_run_turn_body remote_client_reconcile_session remote_client_model_ensure remote_client_request remote_client_idle_cancel agent_emit agent_set_status ui_append_message ui_refresh_all ui_activity_begin ui_activity_end _remote_http_send _remote_server_model_ensure _remote_server_start_turn _remote_server_model_poll input_queue_open; do
    saved[$name]="${functions[$name]:-}"
  done
  {
    document_context_snapshot; snapshot="$REPLY"
    assert_eq '["docs/one file.md","docs/two.markdown"]' "$snapshot" 'tab order and workspace-relative paths are preserved'
    document_context_validate "$snapshot"
    assert_success 'open path metadata validates' $?
    assert_eq "$snapshot" "$REPLY" 'validation preserves path identity'
    for candidate in '[42]' '["a.md",]' '["a.md"] trailing' '["../a.md"]' '["/a.md"]' '["a.txt"]' '["a.md","b.md","c.md","d.md","e.md"]' '["a\u0000.md"]'; do
      document_context_validate "$candidate"
      assert_failure "invalid open document metadata is rejected: $candidate" $?
    done
    # The production turn boundary holds the submission snapshot while tabs change.
    _agent_run_turn_body() {
      captured_documents="$AGENT_OPEN_DOCUMENTS"
      UI_DOCUMENT_PATHS=()
      agent_build_payload false '[]'; captured="$REPLY"
    }
    _agent_run_turn 'Read the open docs' user 'Read the open docs'
    assert_eq "$snapshot" "$captured_documents" 'local turns capture every open document before work begins'
    assert_contains "$captured" 'docs/one file.md' 'open document paths reach the model system prompt'
    assert_not_contains "$captured" 'PRIVATE' 'document source text is excluded from the model payload'
    _agent_run_turn 'Next task' user 'Next task'
    assert_eq '[]' "$captured_documents" 'closing all tabs clears the next submitted path list'
    assert_not_contains "$captured" 'docs/one file.md' 'closed paths are absent from the next system prompt'
    local AGENT_OPEN_DOCUMENTS='["docs/<tag>.md"]'
    document_context_prompt_block
    assert_contains "$REPLY" '\u003ctag\u003e.md' 'filenames cannot inject prompt markup'
    AGENT_OPEN_DOCUMENTS=''
    UI_ACTIVE=0
    _agent_run_turn task user task
    assert_eq '' "$captured_documents" 'headless turns do not inherit closed UI tabs'

    # Capture real client payloads without a network or model request.
    remote_client_reconcile_session() { return 0; }
    remote_client_model_ensure() { return 0; }
    remote_client_idle_cancel() { return 0; }
    agent_emit() { :; }; agent_set_status() { :; }
    ui_append_message() { :; }; ui_refresh_all() { :; }
    ui_activity_begin() { :; }; ui_activity_end() { :; }
    remote_client_request() {
      captured="$3"
      if [[ "$2" == /v1/input ]]; then
        HTTP_BODY='{"message_id":"docs-id","state":"accepted"}'; return 0
      fi
      REMOTE_ERROR=fixture-stop; return 1
    }
    UI_ACTIVE=1; UI_DOCUMENT_PATHS=(4 'docs/one file.md' 6 'docs/two.markdown')
    remote_client_user_turn 'Read the open docs'
    json_parse_flat_object "$captured"
    assert_eq 'Read the open docs' "${JSON_OBJECT[prompt]}" 'remote prompt text stays unchanged'
    assert_eq "$snapshot" "${JSON_OBJECT[open_documents]}" 'remote turns carry only the path snapshot'
    assert_not_contains "$captured" 'PRIVATE' 'remote turn payload excludes document contents'
    remote_client_submit_input docs-id steer 'Read the open docs' "$snapshot"
    json_parse_flat_object "$captured"
    assert_eq "$snapshot" "${JSON_OBJECT[open_documents]}" 'remote steering carries the submitted paths'
    REMOTE_DOCUMENT_CONTEXT_SUPPORTED=false
    remote_client_user_turn 'Read docs/one file.md'
    assert_not_contains "$captured" open_documents 'legacy remote servers receive the original protocol fields'

    # Admission validates before model work; warm-up preserves the same snapshot.
    _remote_http_send() { response_status=$2; }
    _remote_server_model_ensure() { return 0; }
    _remote_server_model_poll() { REMOTE_MODEL_STATUS=ready; }
    input_queue_open() { return 0; }
    _remote_server_start_turn() { captured_documents="${5:-}"; REPLY=fixture; }
    zf_mkdir -p "$REMOTE_RUNTIME_DIR/events" "$REMOTE_RUNTIME_DIR/approvals"
    zjson_quote "$snapshot"
    REMOTE_REQUEST_BODY='{"prompt":"Read the open docs","open_documents":'"$REPLY"'}'
    _remote_server_dispatch_request 0
    assert_eq 202 "$response_status" 'server accepts valid path metadata'
    assert_eq "$snapshot" "$captured_documents" 'server forwards paths to the worker'
    REMOTE_REQUEST_BODY='{"prompt":"Read the open docs","open_documents":"[42]"}'
    _remote_server_dispatch_request 0
    assert_eq 400 "$response_status" 'server rejects malformed path lists'
    REMOTE_REQUEST_BODY='{"prompt":"Next task"}'
    _remote_server_dispatch_request 0
    assert_eq '' "$captured_documents" 'a later client without metadata cannot inherit another client paths'
    REMOTE_MODEL_STATUS=warming
    _remote_server_queue_turn 'Read the open docs' 0 "$snapshot"
    _remote_server_progress_pending_turn
    assert_eq "$snapshot" "$captured_documents" 'warm-up queues retain the submitted path snapshot'
    [[ ! -f "$REMOTE_RUNTIME_DIR/pending_open_documents" ]]
    assert_success 'starting a queued turn removes temporary path metadata' $?
  } always {
    for name in "${(@k)saved}"; do
      if [[ -n "${saved[$name]}" ]]; then functions[$name]="${saved[$name]}"; else unfunction "$name"; fi
    done
  }
}
document_context_tests

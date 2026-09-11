# Exercise the real queue and agent loop with deterministic model boundaries.
input_queue_tests() {
  local ZCODER_SESSIONS_DIR="$TEST_TMP/input-sessions" CURRENT_SESSION_ID=9000000000_1
  local ZCODER_WORKSPACE="$TEST_TMP" ZCODER_PROFILE=coding ZCODER_MODEL=queue-fixture
  local REMOTE_MODE=local REMOTE_TURN_ID='' ACP_INPUT_TURN_ID='' INPUT_QUEUE_TURN_ID=first
  local ZCODER_TOOL_EXPOSURE=full ZCODER_STREAM=false AGENT_CONTEXT_TOOLS='[]'
  local AGENT_SYSTEM_PROMPT=fixture SESSION_TITLE='New Job' STATE_SAVED_SESSION_ID=''
  local -i STATE_ENABLED=1 STATE_LOADING=0 UI_ACTIVE=0 ACP_WORKER_ACTIVE=0 REMOTE_SERVER_WORKER=0
  local -i AGENT_REQUIRE_FINISH_TOOL=0 AGENT_WARMUP_ACTIVE=0 AGENT_TRANSPORT_RETRY_LIMIT=0
  local -a AGENT_MESSAGES=() AGENT_USER_MESSAGES=() SKILL_ACTIVE_NAMES=() SKILL_NAMES=() MCP_NAMES=()
  local -A saved=()
  local name='' queue_dir="$ZCODER_SESSIONS_DIR/$CURRENT_SESSION_ID.session/input_queue"
  local -i before=0 requests=0 tool_count=0 fail_request=0 queue_id=0
  local -a payloads=() emitted=()
  for name in agent_prepare_payload agent_ollama_chat tool_dispatch agent_emit agent_set_status agent_tool_event skills_activate_explicit_from_text agent_context_refresh_after_response; do
    saved[$name]="${functions[$name]}"
  done
  agent_prepare_payload() { agent_build_payload false '[]'; }
  agent_set_status() { :; }
  agent_tool_event() { :; }
  agent_emit() { emitted+=("$1:$2"); }
  agent_context_refresh_after_response() { :; }
  skills_activate_explicit_from_text() { :; }
  {
    transcript_reset
    agent_reset
    state_save_session
    input_queue_open "$CURRENT_SESSION_ID" first
    assert_success 'a saved session opens private input admission' $?
    input_queue_submit "$CURRENT_SESSION_ID" first one steer $'Exact 世界\nsecond line\n'
    assert_success 'queued input preserves Unicode and trailing newlines' $?
    assert_contains "$REPLY" '"state":"accepted"' 'acceptance is distinct from consumption'
    input_queue_submit "$CURRENT_SESSION_ID" first one steer $'Exact 世界\nsecond line\n'
    assert_success 'retrying the same message ID is idempotent' $?
    input_queue_submit "$CURRENT_SESSION_ID" first one steer different
    assert_failure 'an existing ID cannot be reused for different content' $?
    input_queue_submit "$CURRENT_SESSION_ID" stale two steer wrong
    assert_failure 'stale turn IDs cannot inject input into the next turn' $?
    input_queue_submit "$CURRENT_SESSION_ID" first ../escape steer wrong
    assert_failure 'message IDs cannot escape private queue storage' $?
    input_queue_submit "$CURRENT_SESSION_ID" first two follow_up 'Later task'
    input_queue_has_steer
    assert_success 'steering is detected without consuming it' $?
    assert_eq 0 "${#AGENT_MESSAGES}" 'acceptance does not mutate broker conversation history'
    input_queue_drain steer
    assert_success 'the conversation owner consumes steering at a boundary' $?
    assert_eq 1 "${#AGENT_MESSAGES}" 'a follow-up is not consumed with steering'
    agent_history_payload_json
    assert_not_contains "$REPLY" input_id 'receipt metadata never enters the Ollama payload'
    assert_contains "$REPLY" 'Exact 世界\nsecond line\n' 'transport preserves the exact queued content'
    input_queue_status "$CURRENT_SESSION_ID" one
    assert_contains "$REPLY" '"state":"consumed"' 'history persistence precedes the consumed receipt'

    # Simulate death between history save and receipt publication, then reload.
    zf_rm -f "$queue_dir/consumed/one"
    STATE_ENABLED=0
    state_load_session "$CURRENT_SESSION_ID"
    STATE_ENABLED=1
    input_queue_drain steer
    assert_success 'recovery repairs an interrupted consumption receipt' $?
    assert_eq 1 "${#AGENT_MESSAGES}" 'recovery does not append an already persisted user message twice'
    input_queue_close
    assert_eq 1 "$?" 'turn completion cannot race past an accepted follow-up'
    input_queue_close true
    assert_success 'cancellation closes admission while retaining pending input' $?
    input_queue_submit "$CURRENT_SESSION_ID" first late steer rejected
    assert_failure 'cancelled turns reject new messages' $?
    input_queue_request list "$CURRENT_SESSION_ID" '' '' '' ''
    assert_contains "$REPLY" 'Later task' 'cancelled pending input remains inspectable'
    assert_contains "$REPLY" '"turn_id":""' 'closed admission is visible to clients'
    input_queue_request drop "$CURRENT_SESSION_ID" '' two '' ''
    assert_contains "$REPLY" discarded 'users can explicitly discard pending input'
    input_queue_submit "$CURRENT_SESSION_ID" first one steer $'Exact 世界\nsecond line\n'
    assert_success 'a completed turn still answers an exact retry' $?

    # A real child publishes while the owner holds separate history arrays.
    input_queue_open "$CURRENT_SESSION_ID" first
    (input_queue_submit "$CURRENT_SESSION_ID" first child steer 'From another process') &
    local child_pid=$!
    wait "$child_pid"
    assert_success 'a separate broker process can publish input' $?
    assert_eq 1 "${#AGENT_MESSAGES}" 'a child publication never edits the owner history prematurely'
    input_queue_drain steer
    assert_eq 2 "${#AGENT_MESSAGES}" 'the owner consumes a separate process publication'
    input_queue_close true

    # Two tools in one response must both finish before either steer is added.
    agent_ollama_chat() {
      (( requests++ ))
      payloads+=("$1")
      if (( requests == 1 )); then
        input_queue_submit "$CURRENT_SESSION_ID" "$INPUT_QUEUE_TURN_ID" stream steer 'Steer during response' || return 1
        input_queue_submit "$CURRENT_SESSION_ID" "$INPUT_QUEUE_TURN_ID" follow follow_up 'Follow-up after task' || return 1
        if (( fail_request )); then AGENT_CANCELLED=1; return 130; fi
        HTTP_BODY='{"message":{"content":"Inspecting","tool_calls":[{"function":{"name":"read_file","arguments":{"path":"a"}}},{"function":{"name":"read_file","arguments":{"path":"b"}}}]},"done":true}'
      else
        HTTP_BODY='{"message":{"content":"Finished"},"done":true}'
      fi
    }
    tool_dispatch() {
      (( tool_count++ ))
      if (( tool_count == 1 )); then
        input_queue_submit "$CURRENT_SESSION_ID" "$INPUT_QUEUE_TURN_ID" tool steer 'Steer during tool' || return 1
      else
        assert_not_contains "${(j:,:)AGENT_MESSAGES}" 'Steer during response' 'the second tool runs before pending steering enters history'
      fi
      TOOL_RESULT="result $tool_count"; TOOL_RESULT_OK=1
    }
    state_new_session
    agent_user_turn 'Initial task'
    assert_success 'queued steering and follow-ups complete through the real agent loop' $?
    assert_eq 3 "$requests" 'steering joins the next request and the follow-up gets a subsequent turn'
    assert_eq 2 "$tool_count" 'steering never skips an in-flight tool batch'
    assert_contains "${payloads[2]}" '"content":"result 2"},{"role":"user","content":"Steer during response"},{"role":"user","content":"Steer during tool"}' 'tool results precede steering in FIFO order'
    assert_not_contains "${payloads[2]}" 'Follow-up after task' 'follow-ups wait for the active task to finish'
    assert_contains "${payloads[3]}" '"role":"assistant","content":"Finished"},{"role":"user","content":"Follow-up after task"}' 'the follow-up begins after the completed assistant answer'
    assert_not_contains "${payloads[3]}" input_id 'live model requests exclude queue metadata'

    # Cancellation preserves both kinds; a fresh normal turn does not consume
    # them implicitly. Explicit resume recovers them under a new active run ID.
    state_new_session
    requests=0; tool_count=0; fail_request=1
    agent_user_turn 'Cancel this'
    assert_eq 130 "$?" 'cancellation retains the normal agent exit status'
    input_queue_status "$CURRENT_SESSION_ID" stream
    assert_contains "$REPLY" accepted 'cancelled steering remains pending'
    fail_request=0; requests=10
    agent_user_turn 'Separate new task'
    input_queue_status "$CURRENT_SESSION_ID" stream
    assert_contains "$REPLY" accepted 'a new prompt leaves abandoned input paused'
    input_queue_command resume
    assert_success 'explicit resume consumes pending input from an earlier run' $?
    input_queue_status "$CURRENT_SESSION_ID" follow
    assert_contains "$REPLY" consumed 'recovery completes queued follow-ups too'

    # HTTP and ACP use the same validation and receipts, with no model work
    # or broker-side history changes inside these handlers.
    local REMOTE_RUNTIME_DIR="$TEST_TMP/input-remote" REMOTE_SESSION_ID="$CURRENT_SESSION_ID"
    local REMOTE_REQUEST_BODY='' captured='' capture_status='' ACP_SESSION_ID="$CURRENT_SESSION_ID"
    local -i ACP_INITIALIZED=1 ACP_WORKER_RUNNING=1
    local -A ACP_SESSION_CWD=("$CURRENT_SESSION_ID" "$TEST_TMP")
    saved[_remote_http_send]="${functions[_remote_http_send]}"
    saved[_remote_http_error]="${functions[_remote_http_error]}"
    saved[_acp_send]="${functions[_acp_send]}"
    _remote_http_send() { capture_status="$2"; captured="$3"; }
    _remote_http_error() { capture_status="$2"; captured="$3"; }
    _acp_send() { captured="$1"; }
    zf_mkdir -p "$REMOTE_RUNTIME_DIR"
    mapfile[$REMOTE_RUNTIME_DIR/active.pid]="$sysparams[pid]"
    input_queue_open "$CURRENT_SESSION_ID" api
    REMOTE_REQUEST_BODY='{"session_id":"'"$CURRENT_SESSION_ID"'","turn_id":"api","message_id":"http","mode":"steer","text":"HTTP input"}'
    before=${#AGENT_MESSAGES}
    _remote_server_input_request ignored submit
    assert_eq 200 "$capture_status" 'the authenticated HTTP handler returns an acceptance receipt'
    assert_contains "$captured" accepted 'HTTP acceptance is explicitly pending'
    _acp_input_request 9 '{"sessionId":"'"$CURRENT_SESSION_ID"'","turnId":"api","messageId":"acp","text":"ACP input"}'
    assert_contains "$captured" '"id":9,"result":' 'ACP input has an independent JSON-RPC response'
    assert_contains "$captured" accepted 'the ACP broker accepts input while a prompt is active'
    assert_eq "$before" "${#AGENT_MESSAGES}" 'both API brokers leave history consumption to the worker'
    _acp_input_request 10 '{"sessionId":"'"$CURRENT_SESSION_ID"'","turnId":"stale","messageId":"stale","text":"Rejected"}'
    assert_contains "$captured" 'no longer accepting' 'ACP rejects steering addressed to an earlier prompt'
    _acp_input_request 11 '{"sessionId":"'"$CURRENT_SESSION_ID"'","action":"list"}'
    assert_contains "$captured" '"turn_id":"api"' 'ACP clients can discover the current run ID'
    _acp_input_request 12 '{"sessionId":"'"$CURRENT_SESSION_ID"'","text":false}'
    assert_contains "$captured" 'text must be a string' 'ACP refuses malformed input without coercion'

    # Forwarded ACP requests must use the server session and run IDs without
    # damaging a surrounding HTTP event read or JSON parser.
    saved[remote_client_request]="${functions[remote_client_request]}"
    local REMOTE_INPUT_SUPPORTED=true HTTP_BODY=outer-response JSON_SOURCE=outer-json
    local forwarded='' response_id=bridge
    remote_client_request() {
      forwarded="$1:$2:$3"
      HTTP_BODY='{"message_id":"'"$response_id"'","state":"accepted"}'
    }
    REMOTE_MODE=client
    _acp_input_request 13 '{"sessionId":"'"$CURRENT_SESSION_ID"'","turnId":"remote-run","messageId":"bridge","mode":"follow_up","text":"Forward this"}'
    assert_contains "$captured" '"message_id":"bridge","state":"accepted"' 'ACP forwards accepted receipts from a remote server'
    assert_contains "$forwarded" 'POST:/v1/input:{"session_id":"'"$CURRENT_SESSION_ID"'","turn_id":"remote-run","message_id":"bridge","mode":"follow_up","text":"Forward this"}' 'remote ACP sends the exact server identity and message'
    JSON_SOURCE=outer-json
    remote_client_input_request submit remote-run bridge steer 'Nested input'
    assert_eq outer-response "$HTTP_BODY" 'nested queue submission preserves an outer HTTP response'
    assert_eq outer-json "$JSON_SOURCE" 'nested queue submission preserves the outer JSON parser'
    response_id=wrong-id
    remote_client_input_request submit remote-run bridge steer 'Nested input'
    assert_failure 'a mismatched remote receipt cannot clear the submitted draft' $?
    REMOTE_INPUT_SUPPORTED=false
    remote_client_input_request submit remote-run bridge steer 'Nested input'
    assert_failure 'legacy remote servers do not receive unsupported input requests' $?
    REMOTE_MODE=local
    zf_rm -f "$REMOTE_RUNTIME_DIR/active.pid"
    REMOTE_REQUEST_BODY='{"session_id":"'"$CURRENT_SESSION_ID"'"}'
    _remote_server_input_request ignored list
    assert_contains "$captured" '"turn_id":""' 'a restarted server does not advertise abandoned admission'
  } always {
    for name in "${(@k)saved}"; do functions[$name]="${saved[$name]}"; done
  }
}
input_queue_tests
unfunction input_queue_tests

input_queue_pty_tests() {
  zmodload zsh/zpty || return 1
  local base="$TEST_TMP/input-queue-ui" chunk='' expected='' file=''
  local -F deadline=0
  input_queue_fixture() {
    trap - EXIT INT TERM
    exec zsh -f "$TEST_DIR/fixtures/input_queue_ui.zsh" "$PROJECT_DIR" "$base"
  }
  input_queue_wait() {
    local file="$1" expected="$2"
    local -F deadline=$(( EPOCHREALTIME + 10 ))
    while (( EPOCHREALTIME < deadline )); do
      while zpty -r input-queue chunk 2>/dev/null; do :; done
      [[ "${mapfile[$file]:-}" == *"$expected"* ]] && return 0
      zselect -t 1
    done
    return 1
  }
  TERM=xterm-256color zpty -b input-queue input_queue_fixture
  {
    input_queue_wait "$base.started" deliver:1
    assert_success 'the queue PTY reaches an active model wait' $?
    zpty -w -n input-queue $'\e[200~Steering 世界\nline two\e[201~\r'
    input_queue_wait "$base.pending" 'Steering 世界\nline two'
    assert_success 'Enter queues pasted multiline input during generation' $?
    assert_eq '' "${mapfile[$base.draft]:-}" 'acceptance clears the live editor'
    assert_not_contains "${mapfile[$base.request_1]:-}" 'Steering' 'queued text does not alter an in-flight model request'
    zpty -w -n input-queue $'! print -r -- bang-evidence\r'
    input_queue_wait "$base.pending" 'bang-evidence'
    assert_success 'Enter queues a shell command during generation' $?
    zpty -w -n input-queue $'Next task\x07'
    input_queue_wait "$base.pending" 'Next task'
    assert_success 'Ctrl+G queues a follow-up while the response is still running' $?
    mapfile[$base.release_deliver]=1
    input_queue_wait "$base.result" 0:3:
    assert_success 'the PTY completes steering and the follow-up in three model requests' $?
    assert_contains "${mapfile[$base.request_2]:-}" 'file evidence' 'the next request includes completed tool evidence'
    assert_contains "${mapfile[$base.request_2]:-}" 'Steering 世界\nline two' 'the next request receives the exact steering text'
    assert_not_contains "${mapfile[$base.request_2]:-}" 'Next task' 'the PTY keeps follow-ups out of the active task'
    assert_not_contains "${mapfile[$base.request_2]:-}" 'bang-evidence' 'shell output waits until the active task finishes'
    assert_contains "${mapfile[$base.request_3]:-}" 'Next task' 'the follow-up is submitted after task completion'
    assert_contains "${mapfile[$base.request_3]:-}" 'bang-evidence' 'the subsequent request sees queued shell output'
    assert_contains "${mapfile[$base.shell_visible]:-}" '1:Exit code: 0' 'user shell output appears in an expanded transcript block'
    input_queue_wait "$base.started" cancel:
    zpty -w -n input-queue $'Keep this pending\rUnsent draft\e'
    input_queue_wait "$base.cancelled" '130:Unsent draft'
    assert_success 'Escape cancels work and preserves an unsent draft' $?
    input_queue_wait "$base.done" 1
    assert_contains "${mapfile[$base.cancel_pending]:-}" 'Keep this pending' 'accepted input survives PTY cancellation'
    assert_contains "${mapfile[$base.cancel_pending]:-}" '"turn_id":""' 'cancellation closes input admission'
  } always {
    zpty -d input-queue 2>/dev/null
    unfunction input_queue_fixture input_queue_wait
  }
}
input_queue_pty_tests
unfunction input_queue_pty_tests

input_queue_acp_tests() {
  local base="$TEST_TMP/input-queue-acp" line='' output='' session='' turn='' queue_pid=''
  local -F deadline=$(( EPOCHREALTIME + 10 ))
  coproc {
    trap - EXIT INT TERM
    exec zsh -f "$TEST_DIR/fixtures/input_queue_acp.zsh" "$PROJECT_DIR" "$base"
  }
  queue_pid=$!
  input_queue_acp_wait() {
    local match="$1" line=''
    local -F deadline=$(( EPOCHREALTIME + 10 ))
    while (( EPOCHREALTIME < deadline )); do
      if IFS= read -r -p -t 0.1 line; then
        output+="$line"$'\n'
        [[ "$line" == *"$match"* ]] && return 0
      fi
    done
    return 1
  }
  {
    while [[ ! -f "$base.session" ]] && (( EPOCHREALTIME < deadline )); do zselect -t 1; done
    session="${mapfile[$base.session]:-}"
    print -p -r -- '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}'
    input_queue_acp_wait '"zcoder/inputQueue":true'
    assert_success 'a live ACP broker advertises the queue extension' $?
    print -p -r -- '{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"'"$session"'","prompt":[{"type":"text","text":"Original request"}]}}'
    while [[ ! -f "$base.started" ]] && (( EPOCHREALTIME < deadline )); do zselect -t 1; done
    turn="${mapfile[$base.started]:-}"
    [[ -n "$turn" ]]
    assert_success 'a live ACP prompt worker owns a matching input run' $?
    print -p -r -- '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{}}'
    input_queue_acp_wait 'another prompt is already running'
    assert_success 'ordinary concurrent ACP prompts remain rejected' $?
    print -p -r -- '{"jsonrpc":"2.0","id":4,"method":"_zcoder/input","params":{"sessionId":"'"$session"'","turnId":"'"$turn"'","messageId":"live-steer","text":"Steer from broker"}}'
    input_queue_acp_wait '"message_id":"live-steer","state":"accepted"'
    assert_success 'the broker acknowledges steering before its prompt worker finishes' $?
    print -p -r -- '{"jsonrpc":"2.0","id":5,"method":"_zcoder/input","params":{"sessionId":"'"$session"'","turnId":"'"$turn"'","messageId":"live-follow","mode":"follow_up","text":"Follow from broker"}}'
    input_queue_acp_wait '"message_id":"live-follow","state":"accepted"'
    assert_success 'the broker acknowledges a follow-up independently of the active prompt' $?
    mapfile[$base.release]=1
    input_queue_acp_wait '"id":2,"result":{"stopReason":"end_turn"}'
    assert_success 'the original ACP prompt result waits for all queued work' $?
    assert_contains "$output" '"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Steer from broker"}' 'consumed steering uses the existing ACP user update'
    assert_contains "${mapfile[$base.request_2]:-}" 'Steer from broker' 'the worker consumes broker steering after a final response'
    assert_not_contains "${mapfile[$base.request_2]:-}" 'Follow from broker' 'ACP follow-ups wait until steering completes'
    assert_contains "${mapfile[$base.request_3]:-}" 'Follow from broker' 'the worker starts the queued ACP follow-up'
    print -p -r -- '{"jsonrpc":"2.0","id":6,"method":"_zcoder/input","params":{"sessionId":"'"$session"'","turnId":"'"$turn"'","messageId":"live-steer","text":"Steer from broker"}}'
    input_queue_acp_wait '"message_id":"live-steer","state":"consumed"'
    assert_success 'an exact ACP retry after prompt completion returns the consumed receipt' $?
  } always {
    kill -TERM "$queue_pid" 2>/dev/null || true
    wait "$queue_pid" 2>/dev/null || true
    unfunction input_queue_acp_wait
  }
}
input_queue_acp_tests
unfunction input_queue_acp_tests

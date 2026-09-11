# User commands execute through the real approval/execution path, without Ollama.
user_shell_tests() {
  local ZCODER_SESSIONS_DIR="$TEST_TMP/shell-sessions" CURRENT_SESSION_ID=9000000000_2
  local ZCODER_WORKSPACE="$TEST_TMP/shell space's" ZCODER_PROFILE=coding ZCODER_MODEL=shell-fixture
  local ZCODER_COMMAND_POLICY=allow ZCODER_TOOL_EXPOSURE=full ZCODER_STREAM=false
  local REMOTE_MODE=local REMOTE_TURN_ID='' ACP_INPUT_TURN_ID='' INPUT_QUEUE_TURN_ID=''
  local AGENT_CONTEXT_TOOLS='[]' AGENT_SYSTEM_PROMPT=fixture SESSION_TITLE='New Job'
  local -i STATE_ENABLED=1 STATE_LOADING=0 UI_ACTIVE=0 ACP_WORKER_ACTIVE=0 REMOTE_SERVER_WORKER=0
  local -i AGENT_REQUIRE_FINISH_TOOL=0 AGENT_WARMUP_ACTIVE=0 AGENT_TRANSPORT_RETRY_LIMIT=0
  local -i ZCODER_MAX_TOOL_OUTPUT=32768 requests=0 queue_shell=0 approvals=0
  local -a AGENT_MESSAGES=() AGENT_USER_MESSAGES=() SKILL_ACTIVE_NAMES=() SKILL_NAMES=() MCP_NAMES=()
  local -a emitted=() payloads=() updates=()
  local -A saved=()
  local name='' queue_dir='' captured='' command_text='' forwarded=''
  for name in agent_prepare_payload agent_ollama_chat agent_emit agent_set_status agent_context_refresh_after_response ui_confirm_command remote_client_user_turn _acp_notify_update; do
    saved[$name]="${functions[$name]}"
  done
  agent_prepare_payload() { agent_build_payload false '[]'; }
  agent_set_status() { :; }
  agent_context_refresh_after_response() { :; }
  agent_emit() { emitted+=("$1:$2"); }
  ui_confirm_command() { (( approvals++ )); REPLY=n; }
  agent_ollama_chat() {
    (( requests++ ))
    payloads+=("$1")
    if (( queue_shell )); then
      input_queue_submit "$CURRENT_SESSION_ID" "$INPUT_QUEUE_TURN_ID" bang steer '! print -r -- deferred-evidence'
      if (( queue_shell == 1 )); then
        input_queue_submit "$CURRENT_SESSION_ID" "$INPUT_QUEUE_TURN_ID" question steer 'Explain the command output'
      fi
      queue_shell=0
      input_queue_has_steer
      assert_failure 'a shell command keeps subsequent steering behind its output' $?
    fi
    HTTP_BODY='{"message":{"content":"Finished"},"done":true}'
    return 0
  }
  {
    zf_mkdir -p -- "$ZCODER_WORKSPACE"
    transcript_reset
    agent_reset
    state_save_session
    agent_user_turn $'! print -r -- "$PWD"; print -r -- "世界 * $(false)"; print stderr >&2'
    assert_success 'a bang command completes without a model turn' $?
    assert_eq 0 "$requests" 'successful shell output never calls Ollama'
    assert_contains "${(F)emitted}" "$ZCODER_WORKSPACE" 'shell output displays the workspace with spaces and quotes'
    assert_contains "${(F)emitted}" stderr 'shell output includes stderr'
    assert_contains "${(F)emitted}" 'Exit code: 0' 'shell output displays exit status'
    assert_eq 0 "${#AGENT_USER_MESSAGES}" 'shell evidence does not become an actionable user request'
    agent_user_turn 'Explain that output'
    assert_eq 1 "$requests" 'a later explicit request starts the model'
    assert_contains "$payloads[1]" 'User-run shell command' 'later requests receive clearly marked shell evidence'
    assert_contains "$payloads[1]" 'stderr' 'later requests include captured output'
    STATE_ENABLED=0
    state_load_session "$CURRENT_SESSION_ID"
    STATE_ENABLED=1
    assert_contains "${(F)AGENT_MESSAGES}" 'stderr' 'saved sessions retain shell evidence'

    ZCODER_COMMAND_POLICY=deny
    agent_user_turn '! print forbidden > denied-side-effect'
    [[ ! -e "$ZCODER_WORKSPACE/denied-side-effect" ]]
    assert_success 'bang commands cannot bypass the deny policy' $?
    assert_contains "$AGENT_MESSAGES[-1]" 'user denied command' 'denied commands record the reason'
    ZCODER_COMMAND_POLICY=ask
    agent_user_turn '! print forbidden > denied-side-effect'
    assert_eq 1 "$approvals" 'bang commands use the existing approval callback'
    ZCODER_COMMAND_POLICY=allow
    agent_user_turn '! print failure-detail >&2; exit 7'
    assert_eq 1 "$requests" 'failed commands never trigger a model repair turn'
    assert_contains "$AGENT_MESSAGES[-1]" 'Exit code: 7' 'failed commands retain their actual exit status'
    agent_user_turn $'! \t\n'
    assert_contains "${(F)emitted}" 'Usage: ! command' 'an empty bang command displays help'
    assert_eq 1 "$requests" 'empty bang commands do not call the model'
    ZCODER_MAX_TOOL_OUTPUT=120
    agent_user_turn '! print -rn HEAD; print -rn -- ${(pl:10000::x:)}; print -rn TAIL'
    assert_contains "$AGENT_MESSAGES[-1]" 'omitted' 'large shell results explicitly identify truncation'
    assert_contains "$AGENT_MESSAGES[-1]" TAIL 'truncation retains the end of command output'
    ZCODER_MAX_TOOL_OUTPUT=32768

    state_new_session
    requests=0; payloads=(); queue_shell=1
    agent_user_turn 'Finish this task'
    assert_success 'queued shell commands and later requests drain normally' $?
    assert_eq 2 "$requests" 'queued shell commands do not create an extra model request'
    assert_not_contains "$payloads[1]" deferred-evidence 'the active request cannot see deferred shell output'
    assert_contains "$payloads[2]" 'deferred-evidence' 'the next user request sees the completed command'
    assert_contains "$payloads[2]" 'Explain the command output' 'later steering is delivered after the shell result'
    input_queue_status "$CURRENT_SESSION_ID" bang
    assert_contains "$REPLY" consumed 'queued shell results have a persisted receipt'
    assert_eq 2 "${#AGENT_USER_MESSAGES}" 'queued shell commands stay out of the request ledger'

    # Interrupted delivery must never repeat shell effects, even if the
    # command finished just before its result or receipt could be saved.
    queue_dir="$ZCODER_SESSIONS_DIR/$CURRENT_SESSION_ID.session/input_queue"
    local INPUT_QUEUE_TURN_ID=recovery
    input_queue_open "$CURRENT_SESSION_ID" recovery
    input_queue_submit "$CURRENT_SESSION_ID" recovery lost follow_up '! print twice >> replayed'
    _input_queue_write "$queue_dir/shell-lost.started" started
    input_queue_close true
    input_queue_command resume
    assert_success 'shell-only recovery finishes without a model request' $?
    assert_eq 2 "$requests" 'resuming shell-only input does not wake the model'
    [[ ! -e "$ZCODER_WORKSPACE/replayed" ]]
    assert_success 'recovery never re-executes a previously claimed shell command' $?
    assert_contains "$AGENT_MESSAGES[-1]" 'It was not rerun' 'interrupted shell evidence explains possible side effects'
    local -i before=${#AGENT_MESSAGES}
    zf_rm -f "$queue_dir/consumed/lost"
    input_queue_command resume
    assert_eq "$before" "${#AGENT_MESSAGES}" 'receipt recovery does not duplicate saved shell evidence'

    state_new_session
    queue_shell=2
    agent_user_turn 'Finish before running the queued command'
    assert_success 'a shell-only queue returns to idle after executing the command' $?
    assert_eq 3 "$requests" 'a trailing shell command never requests an automatic response'
    assert_contains "$AGENT_MESSAGES[-1]" deferred-evidence 'a trailing shell command is retained for a future request'

    # ACP output travels through tool events, not fabricated assistant text.
    local ACP_SESSION_ID="$CURRENT_SESSION_ID" ACP_CURRENT_TOOL_CALL_ID=''
    local -i ACP_TOOL_SEQUENCE=0
    _acp_notify_update() { updates+=("$2"); }
    ACP_WORKER_ACTIVE=1
    agent_user_turn '! print acp-shell-output'
    assert_contains "${(F)updates}" '"sessionUpdate":"tool_call"' 'ACP receives the shell tool lifecycle'
    assert_contains "${(F)updates}" acp-shell-output 'ACP receives captured shell output'
    assert_not_contains "${(F)updates}" agent_message_chunk 'ACP shell output does not impersonate a model response'
    ACP_WORKER_ACTIVE=0

    transcript_tool_event begin run_command '{"command":"print hello","cwd":".","user_initiated":true}'
    assert_eq 1 "$UI_BLOCK_OPEN[-1]" 'remote user shell events open their output block without a local UI'
    transcript_tool_event complete run_command '{}' 'Exit code: 0' 1
    assert_contains "$UI_CONTENTS[-1]" 'Working directory: .' 'expanded shell output labels its working directory'

    REMOTE_MODE=client
    remote_client_user_turn() { forwarded="$1"; }
    agent_user_turn '! print remote > client-side-effect'
    assert_eq '! print remote > client-side-effect' "$forwarded" 'remote bang commands go to the selected server'
    [[ ! -e "$ZCODER_WORKSPACE/client-side-effect" ]]
    assert_success 'remote bang commands never execute on the client' $?
  } always {
    for name in "${(@k)saved}"; do
      if [[ -n "${saved[$name]}" ]]; then functions[$name]="${saved[$name]}"; else unfunction "$name" 2>/dev/null; fi
    done
  }
}
user_shell_tests
unfunction user_shell_tests

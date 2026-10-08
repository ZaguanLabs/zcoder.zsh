# Extracted orchestration is callable without curses or Ollama. The full turn
# fixtures separately cover approval, queue takeover, goal verification and IO.
agent_turn_helper_tests() {
  emulate -L zsh
  local -A saved=()
  local name='' REPLY='' payload=$'literal "payload"\n世界 *' tool_name=parent
  local HTTP_BODY='' HTTP_ERROR='' AGENT_LAST_RESPONSE='' AGENT_FINISH_STATUS='' AGENT_FINISH_RESPONSE='' AGENT_FINISH_ERROR=''
  local AGENT_LOOP_REASON='' AGENT_LOOP_NUDGE='' AGENT_LOOP_FORBIDDEN_REQUEST=''
  local -i UI_ACTIVE=0 ACP_WORKER_ACTIVE=0 REMOTE_SERVER_WORKER=0 AGENT_CANCELLED=0 TOOL_CANCELLED=0 TOOL_RESULT_OK=0
  local -i AGENT_TRANSPORT_RETRY_LIMIT=1 AGENT_INCOMPLETE_RETRY_LIMIT=1 AGENT_LOOP_WARNING_ACTIVE=0
  local -i attempts=0 dispatches=0 cancel=0 reject=0 i=91 step=92 patch_failures=93
  local TOOL_RESULT='' TOOL_DIFF=''
  local -a sent=() executed=() history=() events=() reply=() call_names=(parent) call_args=(parent)
  for name in agent_ollama_chat agent_emit agent_set_status agent_tool_event tool_dispatch agent_add_message agent_loop_record agent_loop_detect goal_mark_blocked goal_pause; do
    saved[$name]="${functions[$name]}"
  done
  agent_ollama_chat() {
    (( attempts++ )); sent+=("$1")
    if (( attempts == 1 )); then HTTP_ERROR='cannot connect to Ollama at fixture'; return 1; fi
    HTTP_BODY='response'; HTTP_ERROR=''; return 0
  }
  agent_emit() { events+=("$1:$2"); }
  agent_set_status() { :; }
  agent_tool_event() { events+=("$1:$2"); }
  agent_add_message() { history+=("$1:$2:${3:-}"); }
  agent_loop_record() { :; }
  agent_loop_detect() { return 1; }
  goal_mark_blocked() { events+=("blocked:$1"); }
  goal_pause() { events+=("paused:$1"); }
  tool_dispatch() {
    (( dispatches++ )); executed+=("$1" "$2")
    TOOL_RESULT=done; TOOL_RESULT_OK=1; TOOL_CANCELLED=$cancel
    if (( reject )); then TOOL_RESULT=rejected; TOOL_RESULT_OK=0; fi
    return 0
  }
  {
    agent_request_with_retry "$payload" false 7
    assert_success 'transport helper works without a parent turn' $?
    assert_eq 2 "$attempts" 'transport helper retains bounded replay'
    assert_eq "$payload" "$sent[1]" 'transport helper preserves literal payloads'
    assert_eq "$sent[1]" "$sent[2]" 'transport helper replays the same payload'

    agent_execute_tool_round 7 0 0 0 2 read_file search '' $'line\n世界 *'
    assert_success 'tool-round helper works without a parent turn' $?
    assert_eq 0 "$REPLY" 'tool-round helper returns the patch counter'
    assert_eq 2 "$dispatches" 'tool-round helper executes calls in order'
    assert_eq '' "$executed[2]" 'tool-round arguments preserve empty elements'
    assert_eq $'line\n世界 *' "$executed[4]" 'tool-round arguments preserve multiline Unicode and glob text'
    assert_eq 'parent:91:92:93' "$tool_name:$i:$step:$patch_failures" 'tool-round scratch variables do not overwrite the caller'
    assert_eq parent "$call_names[1]" 'tool-round arrays do not overwrite the caller'

    dispatches=0; executed=(); history=(); cancel=1
    agent_execute_tool_round 8 0 0 0 2 run_command write_file '{}' '{}'
    assert_eq 130 "$?" 'tool-round helper propagates cancellation'
    assert_eq 1 "$dispatches" 'cancellation prevents remaining side effects'
    assert_contains "$history[2]" 'not executed because the user cancelled' 'cancellation closes remaining tool history'
    cancel=0; reject=1
    agent_execute_tool_round 9 0 1 2 1 apply_patch '{}'
    assert_eq 1 "$?" 'tool-round helper stops at the patch rejection limit'
    assert_eq 2 "$REPLY" 'patch rejection count survives an early stop'
    reject=0; dispatches=0
    AGENT_LOOP_WARNING_ACTIVE=1; AGENT_LOOP_FORBIDDEN_REQUEST='9:read_file2:{}'
    agent_execute_tool_round 10 0 0 0 1 read_file '{}'
    assert_eq 1 "$?" 'loop guard can reject a round before dispatch'
    assert_eq 0 "$dispatches" 'loop guard never executes a forbidden round'
    AGENT_LOOP_WARNING_ACTIVE=0

    agent_handle_finish '{"status":"complete","response":"Done"}' '' 11 0 4 0
    assert_eq 0 "$?" 'finish helper completes without a parent turn'
    assert_eq Done "$AGENT_LAST_RESPONSE" 'finish helper owns the accepted final response'
    assert_eq '4,0' "${(j:,:)reply}" 'finish helper returns both recovery counters'
    agent_handle_finish '{}' '' 12 1 4 1
    assert_eq 1 "$?" 'invalid goal finishes respect the recovery limit'
    assert_eq '4,2' "${(j:,:)reply}" 'finish helper returns counters on failure too'
  } always {
    for name in "${(@k)saved}"; do functions[$name]="${saved[$name]}"; done
  }
}
agent_turn_helper_tests
unfunction agent_turn_helper_tests

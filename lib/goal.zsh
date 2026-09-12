# Persistent goal state and independent, read-only completion verification.

typeset -g GOAL_ID=""
typeset -g GOAL_STATUS="none"
typeset -g GOAL_OBJECTIVE=""
typeset -g GOAL_FEEDBACK=""
typeset -g GOAL_BLOCK_REASON=""
typeset -g GOAL_CANDIDATE_RESPONSE=""
typeset -gi GOAL_CREATED_AT=0
typeset -gi GOAL_UPDATED_AT=0
typeset -gi GOAL_ATTEMPTS=0
typeset -gi GOAL_REJECTIONS=0
typeset -gi GOAL_TOKENS_USED=0
typeset -gi GOAL_TOKEN_BUDGET=0
typeset -gi GOAL_VERIFIER_ACTIVE=0
typeset -g GOAL_VERIFIER_VERDICT=""
typeset -g GOAL_VERIFIER_REASON=""
typeset -g GOAL_VERIFIER_NEXT_ACTION=""
typeset -g GOAL_VERIFIER_MISSING_EVIDENCE=""
typeset -gi ZCODER_GOAL_MAX_REJECTIONS="${ZCODER_GOAL_MAX_REJECTIONS:-3}"
typeset -gi ZCODER_GOAL_VERIFIER_MAX_STEPS="${ZCODER_GOAL_VERIFIER_MAX_STEPS:-8}"

(( ZCODER_GOAL_MAX_REJECTIONS > 0 )) || ZCODER_GOAL_MAX_REJECTIONS=3
(( ZCODER_GOAL_VERIFIER_MAX_STEPS > 0 )) || ZCODER_GOAL_VERIFIER_MAX_STEPS=8

goal_reset() {
  GOAL_ID=""
  GOAL_STATUS="none"
  GOAL_OBJECTIVE=""
  GOAL_FEEDBACK=""
  GOAL_BLOCK_REASON=""
  GOAL_CANDIDATE_RESPONSE=""
  GOAL_CREATED_AT=0
  GOAL_UPDATED_AT=0
  GOAL_ATTEMPTS=0
  GOAL_REJECTIONS=0
  GOAL_TOKENS_USED=0
  GOAL_TOKEN_BUDGET=0
  GOAL_VERIFIER_ACTIVE=0
  GOAL_VERIFIER_VERDICT=""
  GOAL_VERIFIER_REASON=""
  GOAL_VERIFIER_NEXT_ACTION=""
  GOAL_VERIFIER_MISSING_EVIDENCE=""
}

goal_is_running() {
  [[ "$GOAL_STATUS" == active || "$GOAL_STATUS" == verifying ]]
}

goal_begin() {
  local objective="$1" token_budget_text="${2:-0}"
  local -i token_budget=0
  [[ -n "$objective" ]] || { REPLY="a goal objective is required"; return 1; }
  [[ "$token_budget_text" == <0-> ]] || { REPLY="the goal token budget must be a non-negative integer"; return 1; }
  (( ${#token_budget_text} <= 18 )) || { REPLY="the goal token budget is too large"; return 1; }
  token_budget=$(( 10#$token_budget_text ))
  if [[ "$GOAL_STATUS" == active || "$GOAL_STATUS" == verifying ]]; then
    REPLY="a goal is already running; pause or clear it before starting another"
    return 1
  fi
  goal_reset
  GOAL_ID="${EPOCHSECONDS}_${RANDOM}"
  GOAL_STATUS="active"
  GOAL_OBJECTIVE="$objective"
  GOAL_CREATED_AT=$EPOCHSECONDS
  GOAL_UPDATED_AT=$EPOCHSECONDS
  GOAL_TOKEN_BUDGET=$token_budget
  REPLY=""
}

goal_pause() {
  local reason="${1:-paused by user}"
  [[ "$GOAL_STATUS" == active || "$GOAL_STATUS" == verifying ]] || return 1
  GOAL_STATUS="paused"
  GOAL_BLOCK_REASON="$reason"
  GOAL_UPDATED_AT=$EPOCHSECONDS
  (( $+functions[state_save_session] )) && state_save_session || true
}

goal_mark_blocked() {
  GOAL_STATUS="blocked"
  GOAL_BLOCK_REASON="$1"
  GOAL_UPDATED_AT=$EPOCHSECONDS
  (( $+functions[state_save_session] )) && state_save_session || true
}

goal_mark_complete() {
  GOAL_STATUS="complete"
  GOAL_FEEDBACK=""
  GOAL_BLOCK_REASON=""
  GOAL_UPDATED_AT=$EPOCHSECONDS
  (( $+functions[state_save_session] )) && state_save_session || true
}

goal_account_tokens() {
  local -i prompt_tokens="${1:-0}" output_tokens="${2:-0}"
  (( prompt_tokens >= 0 )) || prompt_tokens=0
  (( output_tokens >= 0 )) || output_tokens=0
  (( GOAL_TOKENS_USED += prompt_tokens + output_tokens ))
  GOAL_UPDATED_AT=$EPOCHSECONDS
}

goal_budget_exhausted() {
  (( GOAL_TOKEN_BUDGET > 0 && GOAL_TOKENS_USED >= GOAL_TOKEN_BUDGET ))
}

goal_status_text() {
  local budget="unlimited" reason=""
  (( GOAL_TOKEN_BUDGET > 0 )) && budget="${GOAL_TOKENS_USED}/${GOAL_TOKEN_BUDGET} tokens" || budget="${GOAL_TOKENS_USED} tokens (no limit)"
  if [[ "$GOAL_STATUS" == none ]]; then
    REPLY="No goal is set. Start one with /goal OBJECTIVE."
    return
  fi
  [[ -n "$GOAL_BLOCK_REASON" ]] && reason=$'\n'"Reason: ${GOAL_BLOCK_REASON}"
  REPLY="Goal ${GOAL_STATUS}: ${GOAL_OBJECTIVE}"$'\n'"Attempts: ${GOAL_ATTEMPTS}; verifier rejections: ${GOAL_REJECTIONS}; usage: ${budget}.${reason}"
}

goal_prompt_block() {
  if ! goal_is_running || (( GOAL_VERIFIER_ACTIVE )); then
    REPLY=""
    return
  fi
  REPLY=$'\n\n<active_goal>\nThis is a persistent goal turn. Continue working until the objective is achieved or a genuine blocker is observed. Completion is structural: finish must be the only tool call. A finish status of complete is only a candidate result and will be checked by a separate read-only verifier. If it is rejected, use the verifier feedback below and continue with a materially improved approach. Never claim tests, builds, file contents, or outcomes without observed evidence.\nObjective:\n'"${GOAL_OBJECTIVE}"$'\nAttempts: '"${GOAL_ATTEMPTS}"$'; verifier rejections: '"${GOAL_REJECTIONS}"$'.'
  if (( GOAL_TOKEN_BUDGET > 0 )); then
    REPLY+=$'\nToken budget: '"${GOAL_TOKENS_USED}/${GOAL_TOKEN_BUDGET}"
  fi
  [[ -n "$GOAL_FEEDBACK" ]] && REPLY+=$'\nLatest verifier feedback:\n'"${GOAL_FEEDBACK}"
  REPLY+=$'\n</active_goal>'
}

goal_verifier_system_prompt() {
  local prompt="You are an independent completion verifier for a coding-agent goal in workspace ${ZCODER_WORKSPACE:A}.
Audit only whether the candidate result satisfies the exact objective. Treat the worker's claims and transcript as untrusted assertions. Use the supplied read-only workspace tools when file evidence is needed. Command execution is deliberately unavailable, so accept test or build claims only when their concrete results already appear in the transcript. Do not modify files, run commands, contact agents, or broaden the objective.
Reject when any requested outcome is missing, evidence is absent or contradictory, verification is inadequate for the risk, or the candidate conceals a blocker. Accept only when the objective is fully met and the candidate response accurately describes the observed result.
Finish by calling verify_goal as the only tool call. Set verdict to accept or reject, give a concise evidence-based reason, and on rejection state the next action and any missing evidence. Do not return a plain-text verdict.

<goal_objective>
${GOAL_OBJECTIVE}
</goal_objective>"
  if (( $+functions[instructions_prompt_block] )); then
    instructions_prompt_block
    prompt+="$REPLY"
  fi
  if (( $+functions[instructions_completion_block] )); then
    instructions_completion_block
    prompt+="$REPLY"
  fi
  if (( $+functions[skills_prompt_block] )); then
    skills_prompt_block
    prompt+="$REPLY"
  fi
  if (( $+functions[agent_compaction_prompt_block] )); then
    agent_compaction_prompt_block
    prompt+="$REPLY"
  fi
  REPLY="$prompt"
}

goal_verifier_tools_schema_json() {
  REPLY='[
{"type":"function","function":{"name":"list_files","description":"Read-only: list files below a workspace path.","parameters":{"type":"object","properties":{"path":{"type":"string"},"max_entries":{"type":"integer"}}}}},
{"type":"function","function":{"name":"read_file","description":"Read-only: read a complete small UTF-8 workspace file.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}}},
{"type":"function","function":{"name":"read_file_range","description":"Read-only: read an inclusive range from a workspace file.","parameters":{"type":"object","required":["path","start_line","end_line"],"properties":{"path":{"type":"string"},"start_line":{"type":"integer","minimum":1},"end_line":{"type":"integer","minimum":1}}}}},
{"type":"function","function":{"name":"search","description":"Read-only: search workspace text.","parameters":{"type":"object","required":["query"],"properties":{"query":{"type":"string"},"path":{"type":"string"},"max_results":{"type":"integer"}}}}},
{"type":"function","function":{"name":"verify_goal","description":"Return the independent goal verdict. This must be the only tool call in the response.","parameters":{"type":"object","required":["verdict","reason"],"properties":{"verdict":{"type":"string","enum":["accept","reject"]},"reason":{"type":"string"},"next_action":{"type":"string"},"missing_evidence":{"type":"string"}}}}}
]'
}

goal_verifier_dispatch_read() {
  local name="$1" args_json="$2"
  TOOL_CANCELLED=0
  if ! json_parse_flat_object "$args_json"; then
    _tool_fail "invalid verifier arguments for $name: ${ZJSON_ERROR:-parse error}"
    return 1
  fi
  case "$name" in
    list_files) tool_list_files "${JSON_OBJECT[path]:-.}" "${JSON_OBJECT[max_entries]:-100}" ;;
    read_file) tool_read_file "${JSON_OBJECT[path]:-}" ;;
    read_file_range) tool_read_file_range "${JSON_OBJECT[path]:-}" "${JSON_OBJECT[start_line]:-}" "${JSON_OBJECT[end_line]:-}" ;;
    search) tool_search "${JSON_OBJECT[query]:-}" "${JSON_OBJECT[path]:-.}" "${JSON_OBJECT[max_results]:-50}" ;;
    *) _tool_fail "tool $name is unavailable to the read-only goal verifier" ;;
  esac
}

goal_parse_verdict() {
  local args_json="$1" verdict="" reason=""
  GOAL_VERIFIER_VERDICT=""
  GOAL_VERIFIER_REASON=""
  GOAL_VERIFIER_NEXT_ACTION=""
  GOAL_VERIFIER_MISSING_EVIDENCE=""
  if ! json_parse_flat_object "$args_json"; then
    REPLY="invalid verify_goal arguments: ${ZJSON_ERROR:-parse error}"
    return 1
  fi
  verdict="${JSON_OBJECT[verdict]:-}"
  reason="${JSON_OBJECT[reason]:-}"
  [[ "$verdict" == accept || "$verdict" == reject ]] || { REPLY="verdict must be accept or reject"; return 1; }
  [[ -n "$reason" ]] || { REPLY="verifier reason must not be empty"; return 1; }
  GOAL_VERIFIER_VERDICT="$verdict"
  GOAL_VERIFIER_REASON="$reason"
  GOAL_VERIFIER_NEXT_ACTION="${JSON_OBJECT[next_action]:-}"
  GOAL_VERIFIER_MISSING_EVIDENCE="${JSON_OBJECT[missing_evidence]:-}"
  REPLY=""
}

goal_verify_candidate() {
  local candidate="$1" payload="" response="" content="" thinking="" calls_json="[]" tool_name="" tool_args="" result="" notice=""
  local -a verifier_history=("${AGENT_MESSAGES[@]}") call_names=() call_args=()
  local -a AGENT_MESSAGES=("${verifier_history[@]}")
  local AGENT_CONTEXT_TOOLS=''
  local AGENT_SYSTEM_PROMPT=""
  local -i GOAL_VERIFIER_ACTIVE=1 step=0 request_status=0

  GOAL_VERIFIER_VERDICT=""
  GOAL_VERIFIER_REASON=""
  GOAL_VERIFIER_NEXT_ACTION=""
  GOAL_VERIFIER_MISSING_EVIDENCE=""
  agent_add_message tool "Candidate completion submitted for independent verification." finish
  agent_add_context_message "Audit this candidate completion against the active objective and transcript evidence. Candidate response:"$'\n'"${candidate}"
  while (( step < ZCODER_GOAL_VERIFIER_MAX_STEPS )); do
    if (( step > 0 )) && goal_budget_exhausted; then
      GOAL_VERIFIER_VERDICT="budget_limited"
      GOAL_VERIFIER_REASON="goal token budget was reached during verification"
      return 3
    fi
    (( step++ ))
    agent_set_status "Goal verifying ${step}"
    agent_build_payload || return $?
    payload="$REPLY"
    agent_ollama_chat "$payload" "$OLLAMA_HOST"
    request_status=$?
    if (( request_status != 0 )); then
      GOAL_VERIFIER_VERDICT="error"
      GOAL_VERIFIER_REASON="${HTTP_ERROR:-goal verifier request failed}"
      (( ${AGENT_CANCELLED:-0} )) && return 130
      return 2
    fi
    response="$HTTP_BODY"
    if ! json_parse_ollama_response "$response"; then
      agent_add_context_message "The verifier response was malformed. Call one read-only evidence tool, or call verify_goal as the only tool with a valid verdict."
      continue
    fi
    goal_account_tokens "$JSON_RESPONSE_PROMPT_TOKENS" "$JSON_RESPONSE_OUTPUT_TOKENS"
    if [[ -n "$JSON_RESPONSE_ERROR" ]]; then
      GOAL_VERIFIER_VERDICT="error"
      GOAL_VERIFIER_REASON="$JSON_RESPONSE_ERROR"
      return 2
    fi
    content="$JSON_RESPONSE_CONTENT"
    thinking="$JSON_RESPONSE_THINKING"
    calls_json="$JSON_RESPONSE_TOOL_CALLS"
    call_names=("${JSON_TOOL_NAMES[@]}")
    call_args=("${JSON_TOOL_ARGS[@]}")
    agent_add_assistant_message "$content" "$thinking" "$calls_json"
    if (( ${#call_names} == 1 )) && [[ "${call_names[1]}" == verify_goal ]]; then
      if goal_parse_verdict "${call_args[1]}"; then
        [[ "$GOAL_VERIFIER_VERDICT" == accept ]]
        return $?
      fi
      agent_add_message tool "Error: $REPLY" verify_goal
      continue
    fi
    if (( ${#call_names} == 1 )); then
      tool_name="${call_names[1]}"
      tool_args="${call_args[1]}"
      goal_verifier_dispatch_read "$tool_name" "$tool_args"
      result="$TOOL_RESULT"
      agent_add_message tool "$result" "$tool_name"
      if (( TOOL_CANCELLED )); then
        GOAL_VERIFIER_VERDICT=cancelled
        GOAL_VERIFIER_REASON='goal evidence search cancelled by user'
        return 130
      fi
      continue
    fi
    notice="Call exactly one read-only evidence tool, or call verify_goal as the only tool. Plain text and multiple tool calls are not a verdict."
    if (( ${#call_names} > 1 )); then
      for tool_name in "${call_names[@]}"; do
        agent_add_message tool "Error: ${notice}" "$tool_name"
      done
    fi
    agent_add_context_message "$notice"
  done
  GOAL_VERIFIER_VERDICT="error"
  GOAL_VERIFIER_REASON="verifier did not return a valid verdict within ${ZCODER_GOAL_VERIFIER_MAX_STEPS} steps"
  return 2
}

goal_rejection_feedback() {
  REPLY="$GOAL_VERIFIER_REASON"
  [[ -n "$GOAL_VERIFIER_NEXT_ACTION" ]] && REPLY+=$'\n'"Next action: ${GOAL_VERIFIER_NEXT_ACTION}"
  [[ -n "$GOAL_VERIFIER_MISSING_EVIDENCE" ]] && REPLY+=$'\n'"Missing evidence: ${GOAL_VERIFIER_MISSING_EVIDENCE}"
}

agent_goal_turn() {
  local objective="$1" origin="${2:-goal}"
  local AGENT_TURN_ORIGIN="$origin"
  (( $+functions[relay_mark_busy] )) && relay_mark_busy || true
  {
    _agent_run_turn "$objective" "$origin" "$objective"
  } always {
    (( $+functions[relay_mark_ready] )) && relay_mark_ready || true
  }
}

goal_handle_command() {
  local text="$1" args="${1#/goal}" objective="" budget_text=""
  local -i token_budget=0 turn_status=0
  args="${args##[[:space:]]#}"
  args="${args%%[[:space:]]#}"
  case "$args" in
    ""|status)
      goal_status_text
      agent_emit system "$REPLY"
      return 0
      ;;
    clear)
      goal_reset
      (( $+functions[state_save_session] )) && state_save_session || true
      agent_emit system "Goal cleared."
      agent_set_status "Ready"
      return 0
      ;;
    pause)
      if goal_pause "paused by user"; then
        agent_emit system "Goal paused. Use /goal resume to continue."
        agent_set_status "Goal paused"
      else
        agent_emit error "No running goal can be paused."
      fi
      return 0
      ;;
    resume)
      if [[ "$GOAL_STATUS" != paused && "$GOAL_STATUS" != blocked && "$GOAL_STATUS" != budget_limited ]]; then
        agent_emit error "No paused or blocked goal can be resumed."
        return 0
      fi
      [[ "$GOAL_STATUS" == budget_limited ]] && GOAL_TOKEN_BUDGET=0
      GOAL_STATUS="active"
      GOAL_BLOCK_REASON=""
      GOAL_ATTEMPTS=0
      GOAL_REJECTIONS=0
      GOAL_UPDATED_AT=$EPOCHSECONDS
      (( $+functions[state_save_session] )) && state_save_session || true
      agent_emit system "Resuming goal: ${GOAL_OBJECTIVE}"
      agent_goal_turn "Continue the persisted goal from the transcript and current workspace state." goal_resume || turn_status=$?
      return "$turn_status"
      ;;
  esac

  if [[ "$args" == --tokens[[:space:]]* ]]; then
    args="${args#--tokens}"
    args="${args##[[:space:]]#}"
    budget_text="${args%%[[:space:]]*}"
    if [[ "$args" == "$budget_text" ]]; then
      agent_emit error "Usage: /goal [--tokens N] OBJECTIVE"
      return 0
    fi
    args="${args#$budget_text}"
    args="${args##[[:space:]]#}"
    [[ "$budget_text" == <1-> ]] || { agent_emit error "Goal token budget must be a positive integer."; return 0; }
    token_budget=$(( 10#$budget_text ))
    (( token_budget > 0 )) || { agent_emit error "Goal token budget must be a positive integer."; return 0; }
  fi
  objective="$args"
  if ! goal_begin "$objective" "$token_budget"; then
    agent_emit error "Could not start goal: $REPLY"
    return 0
  fi
  (( $+functions[state_note_user] )) && state_note_user "$objective"
  (( $+functions[state_save_session] )) && state_save_session || true
  agent_emit system "Goal started. Candidate completion will be checked by an independent read-only verifier."
  agent_goal_turn "$objective" goal || turn_status=$?
  return "$turn_status"
}

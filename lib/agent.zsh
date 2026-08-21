# Ollama conversation state and iterative tool-call loop.

typeset -ga AGENT_MESSAGES=()
typeset -g AGENT_LAST_RESPONSE=""
typeset -gi AGENT_CANCELLED=0
typeset -g AGENT_SYSTEM_PROMPT="${AGENT_SYSTEM_PROMPT:-}"
typeset -gi AGENT_MAX_STEPS="${ZCODER_MAX_TURNS:-${AGENT_MAX_STEPS:-100}}"
typeset -gi AGENT_LOOP_REPEAT_LIMIT="${ZCODER_LOOP_REPEAT_LIMIT:-3}"
typeset -gi AGENT_LOOP_MAX_CYCLE="${ZCODER_LOOP_MAX_CYCLE:-4}"
typeset -gi AGENT_INCOMPLETE_RETRY_LIMIT="${ZCODER_INCOMPLETE_RETRY_LIMIT:-3}"
typeset -gi AGENT_REQUIRE_FINISH_TOOL="${ZCODER_REQUIRE_FINISH_TOOL:-1}"
typeset -g AGENT_CONTINUATION_REASON=""
typeset -g AGENT_FINISH_STATUS=""
typeset -g AGENT_FINISH_RESPONSE=""
typeset -g AGENT_FINISH_ERROR=""
typeset -gi AGENT_LOOP_WARNING_ACTIVE=0
typeset -g AGENT_LOOP_NUDGE=""
typeset -g AGENT_LOOP_REASON=""
typeset -ga AGENT_TOOL_REQUEST_HISTORY=()
typeset -ga AGENT_TOOL_OUTCOME_HISTORY=()
typeset -g ZCODER_MODEL="${ZCODER_MODEL:-qwen3-coder:latest}"
typeset -g ZCODER_THINK="${ZCODER_THINK:-true}"

(( AGENT_MAX_STEPS > 0 )) || AGENT_MAX_STEPS=100
(( AGENT_LOOP_REPEAT_LIMIT >= 2 )) || AGENT_LOOP_REPEAT_LIMIT=3
(( AGENT_LOOP_MAX_CYCLE > 0 )) || AGENT_LOOP_MAX_CYCLE=4
(( AGENT_INCOMPLETE_RETRY_LIMIT >= 0 )) || AGENT_INCOMPLETE_RETRY_LIMIT=3
(( AGENT_REQUIRE_FINISH_TOOL == 0 || AGENT_REQUIRE_FINISH_TOOL == 1 )) || AGENT_REQUIRE_FINISH_TOOL=1

agent_default_system_prompt() {
  REPLY="You are zcoder, an AI coding agent operating in this workspace: ${ZCODER_WORKSPACE:A}.
Use the supplied tools to inspect the project, make requested changes, and verify your work.
Minimize data collection and context use. Do not begin by reading whole source files or recursively listing the entire project. Follow this inspection order:
1. Use search first to locate exact symbols, strings, definitions, and references. It is backed by ripgrep.
   Once search returns a usable location, read that range; do not repeat discovery with minor query variations unless the result is ambiguous.
2. Use list_files only when the project shape is unknown, with the narrowest useful path and a modest max_entries value.
3. Use read_file_range for the relevant sections found by search, normally in chunks of no more than 200 lines. Expand only when the evidence requires it.
4. Use read_file only for clearly small files, or when the entire file is genuinely required. Never read a large source file in full merely to inspect one function or section.
5. If the built-in tools are insufficient, use run_command with targeted commands such as rg --files, rg -n, grep, sed -n, or awk. run_command requires user approval; do not use cat or an unbounded command when search or a ranged read will do.
Stop inspecting once you have enough evidence to act. Read relevant code before editing it. Prefer apply_patch for focused changes and write_file for new or fully replaced files.
Act instead of only narrating: if more work remains, call the appropriate work tool in that response.
Turn completion is structural, not linguistic. When the task is complete or genuinely blocked, call finish as the only tool call, with status complete or blocked and the final user-facing response. Do not return a final answer as plain assistant content, and do not call finish alongside another tool.
Never invent tool results. Keep changes inside the workspace."
}

# Format the curses transcript independently from the tool result stored in
# AGENT_MESSAGES. Read bodies remain available to the model but do not flood
# the user's screen; edits remain visible for review.
agent_format_tool_ui_result() {
  local tool_name="$1" args_json="$2" result="$3"
  local -i succeeded="${4:-0}"
  local path="" start="" end="" content="" label=""
  if ! json_parse_flat_object "$args_json"; then
    (( succeeded )) && label="✓ ${tool_name}" || label="✗ ${tool_name}"
    REPLY="$label"$'\n'"$result"
    return 0
  fi
  path="${JSON_OBJECT[path]:-?}"
  path="${path//$'\n'/ }"
  (( ${#path} > 180 )) && path="${path[1,177]}..."
  case "$tool_name" in
    read_file)
      label="Read(${path})"
      (( succeeded )) && { REPLY="$label"; return 0; }
      ;;
    read_file_range)
      start="${JSON_OBJECT[start_line]:-?}"
      end="${JSON_OBJECT[end_line]:-?}"
      label="Read File Range(${path}:${start}-${end})"
      (( succeeded )) && { REPLY="$label"; return 0; }
      ;;
    write_file)
      content="${JSON_OBJECT[content]:-}"
      label="Write File(${path})"$'\n'"$content"
      ;;
    apply_patch)
      content="${JSON_OBJECT[patch]:-}"
      label="Apply Patch"$'\n'"$content"
      ;;
    *)
      label="$tool_name $args_json"
      ;;
  esac
  if (( succeeded )); then
    REPLY="$label"$'\n'"✓ $result"
  else
    REPLY="$label"$'\n'"✗ $result"
  fi
}

# `finish` is a control-plane tool handled by the agent loop. It is deliberately
# not dispatched to the workspace tool runtime.
agent_parse_finish() {
  local args_json="$1" finish_status="" finish_response=""
  AGENT_FINISH_STATUS=""
  AGENT_FINISH_RESPONSE=""
  AGENT_FINISH_ERROR=""
  if ! json_parse_flat_object "$args_json"; then
    AGENT_FINISH_ERROR="invalid finish arguments: ${JSON_ERROR:-parse error}"
    return 1
  fi
  finish_status="${JSON_OBJECT[status]:-}"
  finish_response="${JSON_OBJECT[response]:-}"
  [[ "$finish_status" == complete || "$finish_status" == blocked ]] || {
    AGENT_FINISH_ERROR="finish status must be complete or blocked"
    return 1
  }
  [[ -n "$finish_response" ]] || {
    AGENT_FINISH_ERROR="finish response must not be empty"
    return 1
  }
  AGENT_FINISH_STATUS="$finish_status"
  AGENT_FINISH_RESPONSE="$finish_response"
  return 0
}

agent_reset() {
  AGENT_MESSAGES=()
  AGENT_LAST_RESPONSE=""
  agent_loop_reset
  agent_compaction_reset
}

agent_loop_reset() {
  AGENT_LOOP_WARNING_ACTIVE=0
  AGENT_LOOP_NUDGE=""
  AGENT_LOOP_REASON=""
  AGENT_TOOL_REQUEST_HISTORY=()
  AGENT_TOOL_OUTCOME_HISTORY=()
}

agent_loop_record() {
  local request_signature="$1" outcome_signature="$2"
  local -i keep=$(( AGENT_LOOP_MAX_CYCLE * (AGENT_LOOP_REPEAT_LIMIT + 1) ))
  AGENT_TOOL_REQUEST_HISTORY+=("$request_signature")
  AGENT_TOOL_OUTCOME_HISTORY+=("$outcome_signature")
  if (( ${#AGENT_TOOL_REQUEST_HISTORY} > keep )); then
    AGENT_TOOL_REQUEST_HISTORY=("${(@)AGENT_TOOL_REQUEST_HISTORY[-$keep,-1]}")
    AGENT_TOOL_OUTCOME_HISTORY=("${(@)AGENT_TOOL_OUTCOME_HISTORY[-$keep,-1]}")
  fi
}

# Return success when the selected history ends with a repeated cycle. REPLY is
# the cycle length, so callers can distinguish a direct repeat from A/B loops.
agent_loop_repeated_suffix() {
  local history_kind="$1"
  local -i repetitions="$2" max_cycle="${3:-$AGENT_LOOP_MAX_CYCLE}"
  local -a history=()
  local -i count cycle required offset same
  case "$history_kind" in
    request) history=("${AGENT_TOOL_REQUEST_HISTORY[@]}") ;;
    outcome) history=("${AGENT_TOOL_OUTCOME_HISTORY[@]}") ;;
    *) return 1 ;;
  esac
  count=${#history}
  for (( cycle=1; cycle<=max_cycle; cycle++ )); do
    required=$(( cycle * repetitions ))
    (( count >= required )) || continue
    same=1
    for (( offset=0; offset<cycle*(repetitions-1); offset++ )); do
      if [[ "${history[count-offset]}" != "${history[count-cycle-offset]}" ]]; then
        same=0
        break
      fi
    done
    if (( same )); then
      REPLY="$cycle"
      return 0
    fi
  done
  return 1
}

agent_loop_detect() {
  local -i cycle request_repetitions=$(( AGENT_LOOP_REPEAT_LIMIT + 1 ))
  local sequence="tool round"
  AGENT_LOOP_REASON=""
  if agent_loop_repeated_suffix outcome "$AGENT_LOOP_REPEAT_LIMIT"; then
    cycle=$REPLY
    (( cycle > 1 )) && sequence="${cycle}-round tool sequence"
    AGENT_LOOP_REASON="the same ${sequence} produced unchanged results ${AGENT_LOOP_REPEAT_LIMIT} times"
    return 0
  fi
  if agent_loop_repeated_suffix request "$request_repetitions"; then
    cycle=$REPLY
    sequence="tool round"
    (( cycle > 1 )) && sequence="${cycle}-round tool sequence"
    AGENT_LOOP_REASON="the same ${sequence} was requested ${request_repetitions} times"
    return 0
  fi
  return 1
}

agent_add_message() {
  local role="$1" content="$2" tool_name="${3:-}" role_json="" content_json="" tool_json=""
  json_quote "$role"; role_json="$REPLY"
  json_quote "$content"; content_json="$REPLY"
  if [[ -n "$tool_name" ]]; then
    json_quote "$tool_name"; tool_json="$REPLY"
    AGENT_MESSAGES+=("{\"role\":${role_json},\"tool_name\":${tool_json},\"content\":${content_json}}")
  else
    AGENT_MESSAGES+=("{\"role\":${role_json},\"content\":${content_json}}")
  fi
  [[ "$role" == user ]] && AGENT_USER_MESSAGES+=("$content")
}

agent_add_assistant_message() {
  local content="$1" thinking="$2" tool_calls="$3"
  local content_json="" thinking_json="" message=""
  json_quote "$content"; content_json="$REPLY"
  message="{\"role\":\"assistant\",\"content\":${content_json}"
  if [[ -n "$thinking" ]]; then
    json_quote "$thinking"; thinking_json="$REPLY"
    message+=",\"thinking\":${thinking_json}"
  fi
  [[ "$tool_calls" != "[]" ]] && message+=",\"tool_calls\":${tool_calls}"
  AGENT_MESSAGES+=("${message}}")
}

agent_build_payload() {
  local model_json="" system_json="" messages="[" comma="" item="" think="true"
  local prompt="$AGENT_SYSTEM_PROMPT"
  [[ -n "$prompt" ]] || { agent_default_system_prompt; prompt="$REPLY"; }
  if (( $+functions[instructions_prompt_block] )); then
    instructions_prompt_block
    prompt+="$REPLY"
  fi
  if [[ -n "$AGENT_COMPACTION_SUMMARY" ]]; then
    prompt+=$'\n\n<compacted_context>\n'"$AGENT_COMPACTION_SUMMARY"$'\n</compacted_context>'
  fi
  [[ -n "$AGENT_LOOP_NUDGE" ]] && prompt+=$'\n\n'"$AGENT_LOOP_NUDGE"
  json_quote "$ZCODER_MODEL"; model_json="$REPLY"
  json_quote "$prompt"; system_json="$REPLY"
  messages+="{\"role\":\"system\",\"content\":${system_json}}"
  comma=","
  for item in "${AGENT_MESSAGES[@]}"; do
    messages+="${comma}${item}"
  done
  messages+="]"
  tools_schema_json
  local tools="$REPLY" options=""
  agent_context_options_json
  options="${REPLY%,}"
  [[ "$ZCODER_THINK" == true || "$ZCODER_THINK" == false ]] || think="false"
  [[ "$ZCODER_THINK" == false ]] && think="false"
  REPLY="{\"model\":${model_json},\"messages\":${messages},\"tools\":${tools},\"stream\":false,\"think\":${think},\"options\":{${options}}}"
}

agent_emit() {
  local role="$1" content="$2" thinking="${3:-}"
  if (( $+functions[ui_append_message] && ${UI_ACTIVE:-0} )); then
    ui_append_message "$role" "$content" "$thinking"
    ui_refresh_all
  else
    case "$role" in
      assistant) print -r -- "$content" ;;
      tool) print -r -- "[tool] $content" ;;
      system) print -r -- "$content" ;;
      error) print -r -- "Error: $content" >&2 ;;
    esac
  fi
}

agent_set_status() {
  if (( $+functions[ui_set_status] && ${UI_ACTIVE:-0} )); then
    ui_set_status "$1"
    ui_draw_header
  fi
}

agent_ollama_chat() {
  local payload="$1" host="${2:-$OLLAMA_HOST}"
  local -i wait_status=0 request_status=0
  AGENT_CANCELLED=0

  if (( ${UI_ACTIVE:-0} && $+functions[ui_wait_for_generation] && $+functions[http_async_start] )); then
    http_async_start POST /api/chat "$payload" "$host" || return 1
    ui_draw_footer
    ui_wait_for_generation
    wait_status=$?
    if (( wait_status == 130 )); then
      http_async_cancel
      AGENT_CANCELLED=1
      ui_draw_footer
      return 130
    elif (( wait_status != 0 )); then
      http_async_cancel
      ui_draw_footer
      return "$wait_status"
    fi
    http_async_collect
    request_status=$?
    ui_draw_footer
    return "$request_status"
  fi

  ollama_chat "$payload" "$host"
}

agent_user_turn() {
  local user_content="$1" payload="" response="" content="" thinking="" calls_json="[]"
  local tool_name="" tool_args="" result="" summary="" display_result=""
  local request_signature="" outcome_signature="" loop_notice="" continuation_notice=""
  local -a call_names=() call_args=()
  local -i step i request_status prepare_status incomplete_retries=0

  AGENT_LAST_RESPONSE=""
  agent_loop_reset
  agent_add_message user "$user_content"
  zcoder_debug user_turn_start "content=${(qqq)user_content}"
  if (( $+functions[ui_append_message] && ${UI_ACTIVE:-0} )); then
    ui_append_message user "$user_content"
    ui_refresh_all
  fi

  for (( step=1; step<=AGENT_MAX_STEPS; step++ )); do
    zcoder_debug model_turn_start "step=$step retries=$incomplete_retries messages=${#AGENT_MESSAGES} estimated_tokens=${AGENT_ESTIMATED_TOKENS:-0}"
    agent_set_status "Thinking ${step}/${AGENT_MAX_STEPS}"
    agent_prepare_payload
    prepare_status=$?
    if (( prepare_status != 0 )); then
      zcoder_debug payload_error "step=$step cancelled=$AGENT_CANCELLED error=${(qqq)HTTP_ERROR}"
      if (( AGENT_CANCELLED )); then
        agent_add_message assistant "[Response generation stopped by user.]"
        agent_emit system "⏹ Response generation stopped."
        agent_set_status "Stopped"
        return 130
      fi
      agent_emit error "Compaction failed: ${HTTP_ERROR:-Ollama request failed}"
      agent_set_status "Compaction error"
      return 1
    fi
    payload="$REPLY"
    agent_set_status "Thinking ${step}/${AGENT_MAX_STEPS}"
    agent_ollama_chat "$payload" "$OLLAMA_HOST"
    request_status=$?
    zcoder_debug ollama_result "step=$step status=$request_status body_chars=${#HTTP_BODY} error=${(qqq)HTTP_ERROR}"
    if (( request_status != 0 )); then
      if (( AGENT_CANCELLED )); then
        agent_add_message assistant "[Response generation stopped by user.]"
        agent_emit system "⏹ Response generation stopped."
        agent_set_status "Stopped"
        return 130
      fi
      response="${HTTP_BODY:-$HTTP_ERROR}"
      if [[ -n "$HTTP_BODY" ]] && json_parse_ollama_response "$HTTP_BODY" && [[ -n "$JSON_RESPONSE_ERROR" ]]; then
        response="$JSON_RESPONSE_ERROR"
      fi
      agent_emit error "${response:-Ollama request failed}"
      agent_set_status "Error"
      return 1
    fi
    response="$HTTP_BODY"
    zcoder_debug ollama_response_raw "step=$step response=${(qqq)response}"
    if ! json_parse_ollama_response "$response"; then
      zcoder_debug response_parse_error "step=$step error=${(qqq)JSON_ERROR}"
      agent_emit error "Could not parse Ollama response: ${JSON_ERROR:-unknown JSON error}"
      agent_set_status "Error"
      return 1
    fi
    if [[ -n "$JSON_RESPONSE_ERROR" ]]; then
      zcoder_debug response_error "step=$step error=${(qqq)JSON_RESPONSE_ERROR}"
      agent_emit error "$JSON_RESPONSE_ERROR"
      agent_set_status "Error"
      return 1
    fi

    _http_byte_length "$payload"
    AGENT_LAST_PAYLOAD_BYTES="$REPLY"
    AGENT_LAST_PROMPT_TOKENS="$JSON_RESPONSE_PROMPT_TOKENS"
    AGENT_LAST_OUTPUT_TOKENS="$JSON_RESPONSE_OUTPUT_TOKENS"
    agent_context_refresh_after_response

    content="$JSON_RESPONSE_CONTENT"
    thinking="$JSON_RESPONSE_THINKING"
    calls_json="$JSON_RESPONSE_TOOL_CALLS"
    call_names=("${JSON_TOOL_NAMES[@]}")
    call_args=("${JSON_TOOL_ARGS[@]}")
    zcoder_debug response_parsed "step=$step content=${(qqq)content} thinking_chars=${#thinking} tool_calls=${#call_names} prompt_tokens=$JSON_RESPONSE_PROMPT_TOKENS output_tokens=$JSON_RESPONSE_OUTPUT_TOKENS"
    agent_add_assistant_message "$content" "$thinking" "$calls_json"

    if (( ${#call_names} == 0 && AGENT_REQUIRE_FINISH_TOOL && AGENT_INCOMPLETE_RETRY_LIMIT > 0 )); then
      AGENT_CONTINUATION_REASON="response omitted both a work tool and the required finish tool"
      zcoder_debug continuation_decision "step=$step retry=$(( incomplete_retries + 1 )) limit=$AGENT_INCOMPLETE_RETRY_LIMIT reason=${(qqq)AGENT_CONTINUATION_REASON} content=${(qqq)content}"
      if (( incomplete_retries < AGENT_INCOMPLETE_RETRY_LIMIT )); then
        (( incomplete_retries++ ))
        continuation_notice="Your previous response omitted the required turn-control tool. If work remains, call the next work tool now. If the task is complete or genuinely blocked, call finish as the only tool with the final response. Do not reply with another plain-text preamble or final answer."
        agent_add_message system "$continuation_notice"
        agent_emit system "↻ Model omitted a work/finish tool; continuing automatically (${incomplete_retries}/${AGENT_INCOMPLETE_RETRY_LIMIT})."
        continue
      fi
      [[ -n "$content" ]] && agent_emit assistant "$content" "$thinking"
      [[ -n "$content" ]] || agent_emit assistant "(The model returned an empty response.)" "$thinking"
      agent_emit error "The model stopped before acting after ${AGENT_INCOMPLETE_RETRY_LIMIT} automatic continuation attempt(s)."
      zcoder_debug continuation_exhausted "step=$step retries=$incomplete_retries reason=${(qqq)AGENT_CONTINUATION_REASON}"
      agent_set_status "Incomplete"
      return 1
    fi

    if (( ${#call_names} == 1 )) && [[ "${call_names[1]}" == finish ]]; then
      tool_args="${call_args[1]}"
      if agent_parse_finish "$tool_args"; then
        agent_add_message tool "finish accepted (${AGENT_FINISH_STATUS})" finish
        agent_add_message assistant "$AGENT_FINISH_RESPONSE"
        AGENT_LAST_RESPONSE="$AGENT_FINISH_RESPONSE"
        agent_emit assistant "$AGENT_FINISH_RESPONSE" "$thinking"
        [[ "$AGENT_FINISH_STATUS" == blocked ]] && agent_set_status "Blocked" || agent_set_status "Ready"
        zcoder_debug finish "step=$step status=$AGENT_FINISH_STATUS response=${(qqq)AGENT_FINISH_RESPONSE}"
        return 0
      fi
      result="Error: $AGENT_FINISH_ERROR"
      agent_add_message tool "$result" finish
      agent_emit error "$result"
      zcoder_debug finish_rejected "step=$step error=${(qqq)AGENT_FINISH_ERROR} args=${(qqq)tool_args}"
      continue
    fi

    if [[ -n "$content" ]]; then
      agent_emit assistant "$content" "$thinking"
      AGENT_LAST_RESPONSE="$content"
    fi
    if (( ${#call_names} == 0 )); then
      [[ -n "$content" ]] || agent_emit assistant "(The model returned an empty response.)" "$thinking"
      agent_set_status "Ready"
      zcoder_debug user_turn_complete "step=$step response=${(qqq)content}"
      return 0
    fi

    request_signature=""
    for (( i=1; i<=${#call_names}; i++ )); do
      tool_name="${call_names[i]}"
      tool_args="${call_args[i]}"
      zcoder_debug tool_call "step=$step index=$i name=${(qqq)tool_name} args=${(qqq)tool_args}"
      request_signature+="${#tool_name}:$tool_name${#tool_args}:$tool_args"
    done
    outcome_signature="$request_signature"
    for (( i=1; i<=${#call_names}; i++ )); do
      tool_name="${call_names[i]}"
      tool_args="${call_args[i]}"
      summary="$tool_name $tool_args"
      (( ${#summary} > 240 )) && summary="${summary[1,237]}..."
      if (( ! ${UI_ACTIVE:-0} )); then
        agent_emit tool "→ $summary"
      fi
      agent_set_status "Tool: $tool_name"
      if [[ "$tool_name" == finish ]]; then
        TOOL_RESULT_OK=0
        TOOL_RESULT="Error: finish must be the only tool call in its response"
      else
        tool_dispatch "$tool_name" "$tool_args"
      fi
      result="$TOOL_RESULT"
      zcoder_debug tool_result "step=$step index=$i name=${(qqq)tool_name} ok=$TOOL_RESULT_OK result_chars=${#result} result_head=${(qqq)${result[1,500]}}"
      outcome_signature+="${TOOL_RESULT_OK}:${#result}:$result"
      agent_add_message tool "$result" "$tool_name"
      if (( ${UI_ACTIVE:-0} )); then
        agent_format_tool_ui_result "$tool_name" "$tool_args" "$result" "$TOOL_RESULT_OK"
        agent_emit tool "$REPLY"
      else
        zcoder_truncate "$result" 2000; display_result="$REPLY"
        if (( TOOL_RESULT_OK )); then
          agent_emit tool "✓ ${tool_name}"$'\n'"$display_result"
        else
          agent_emit tool "✗ ${tool_name}"$'\n'"$display_result"
        fi
      fi
    done

    agent_loop_record "$request_signature" "$outcome_signature"
    if agent_loop_detect; then
      if (( AGENT_LOOP_WARNING_ACTIVE )); then
        agent_emit error "Loop guard stopped the run: ${AGENT_LOOP_REASON}."
        agent_set_status "Loop stopped"
        return 1
      fi
      loop_notice="Loop guard noticed that ${AGENT_LOOP_REASON}. Do not repeat that sequence. Reassess the evidence, choose a materially different action, or explain what blocks further progress."
      AGENT_LOOP_WARNING_ACTIVE=1
      AGENT_LOOP_NUDGE="$loop_notice"
      agent_emit system "⚠ $loop_notice"
    else
      AGENT_LOOP_WARNING_ACTIVE=0
      AGENT_LOOP_NUDGE=""
    fi
  done

  agent_emit error "Emergency stop after ${AGENT_MAX_STEPS} model turns. Continue with a new prompt or raise --max-turns if the task is still making progress."
  agent_set_status "Turn limit"
  return 1
}

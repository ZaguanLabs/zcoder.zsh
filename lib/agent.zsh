# Ollama conversation state and iterative tool-call loop.

typeset -ga AGENT_MESSAGES=()
typeset -ga AGENT_ACCOUNTING_MESSAGES=() AGENT_ACCOUNTING_BYTES=() AGENT_ACCOUNTING_REASONING_BYTES=()
typeset -gi AGENT_ACCOUNTING_CACHE_BYTES=0
# Exact record comparisons keep accounting correct after arbitrary edits. Bound
# their retained copies: large responses and long histories remain uncached.
typeset -gi AGENT_ACCOUNTING_MAX_RECORD_BYTES=4096 AGENT_ACCOUNTING_MAX_CACHE_BYTES=1048576 AGENT_ACCOUNTING_MAX_RECORDS=1024
typeset -g ZCODER_STREAM="${ZCODER_STREAM:-true}"
typeset -ga AGENT_CONTEXT_COMPONENT_LABELS=() AGENT_CONTEXT_COMPONENT_VALUES=()
typeset -g AGENT_CONTEXT_TOOLS=''
typeset -g AGENT_LAST_RESPONSE=""
typeset -gi AGENT_CANCELLED=0
typeset -g AGENT_SYSTEM_PROMPT="${AGENT_SYSTEM_PROMPT:-}"
typeset -gi AGENT_LOOP_REPEAT_LIMIT="${ZCODER_LOOP_REPEAT_LIMIT:-3}"
typeset -gi AGENT_LOOP_MAX_CYCLE="${ZCODER_LOOP_MAX_CYCLE:-4}"
typeset -gi AGENT_INCOMPLETE_RETRY_LIMIT="${ZCODER_INCOMPLETE_RETRY_LIMIT:-3}"
typeset -gi AGENT_TRANSPORT_RETRY_LIMIT="${ZCODER_TRANSPORT_RETRY_LIMIT:-1}"
typeset -gi AGENT_REQUIRE_FINISH_TOOL="${ZCODER_REQUIRE_FINISH_TOOL:-0}"
typeset -g AGENT_CONTINUATION_REASON=""
typeset -g AGENT_FINISH_STATUS=""
typeset -g AGENT_FINISH_RESPONSE=""
typeset -g AGENT_FINISH_ERROR=""
typeset -gi AGENT_LOOP_WARNING_ACTIVE=0
typeset -g AGENT_LOOP_NUDGE=""
typeset -g AGENT_LOOP_REASON=""
typeset -g AGENT_LOOP_FORBIDDEN_REQUEST=""
typeset -g AGENT_RELAY_REPLY_TARGET=""
typeset -ga AGENT_TOOL_REQUEST_HISTORY=()
typeset -ga AGENT_TOOL_OUTCOME_HISTORY=()
typeset -g ZCODER_MODEL="${ZCODER_MODEL:-qwen3-coder:latest}"
typeset -g ZCODER_THINK="${ZCODER_THINK:-true}"
typeset -g ZCODER_PROFILE="${ZCODER_PROFILE:-coding}"
typeset -g ZCODER_WARMUP="${ZCODER_WARMUP:-true}"
typeset -g ZCODER_TOOL_EXPOSURE="${ZCODER_TOOL_EXPOSURE:-full}"
typeset -gi ZCODER_MAX_OUTPUT_TOKENS="${ZCODER_MAX_OUTPUT_TOKENS:-8192}"
typeset -g AGENT_TOOL_PHASE="full"
typeset -g AGENT_ROUTE_MODE=""
typeset -g AGENT_ROUTE_RESPONSE=""
typeset -g AGENT_ROUTE_REASON=""
typeset -g AGENT_ROUTE_ERROR=""
typeset -gi AGENT_WARMUP_ACTIVE=0
typeset -g AGENT_WARMUP_MODEL=""
typeset -g AGENT_WARMUP_HOST=""
typeset -g AGENT_NORMALIZED_CONTENT=""
typeset -g AGENT_NORMALIZED_THINKING=""
typeset -g AGENT_TURN_ORIGIN="user"
typeset -gi AGENT_LFM_BALANCED_PLAN_OBJECTS=0
typeset -gi AGENT_LFM_BALANCED_CALL_OBJECTS=0

(( AGENT_LOOP_REPEAT_LIMIT >= 2 )) || AGENT_LOOP_REPEAT_LIMIT=3
(( AGENT_LOOP_MAX_CYCLE > 0 )) || AGENT_LOOP_MAX_CYCLE=4
(( AGENT_INCOMPLETE_RETRY_LIMIT >= 0 )) || AGENT_INCOMPLETE_RETRY_LIMIT=3
(( AGENT_TRANSPORT_RETRY_LIMIT >= 0 )) || AGENT_TRANSPORT_RETRY_LIMIT=1
(( AGENT_REQUIRE_FINISH_TOOL == 0 || AGENT_REQUIRE_FINISH_TOOL == 1 )) || AGENT_REQUIRE_FINISH_TOOL=0
(( ZCODER_MAX_OUTPUT_TOKENS >= 256 )) || ZCODER_MAX_OUTPUT_TOKENS=8192
[[ "$ZCODER_TOOL_EXPOSURE" == full || "$ZCODER_TOOL_EXPOSURE" == staged ]] || ZCODER_TOOL_EXPOSURE=full

agent_select_profile() {
  case "$1" in
    coding|sysadmin)
      ZCODER_PROFILE="$1"
      REPLY=""
      return 0
      ;;
    *)
      REPLY="profile must be coding or sysadmin"
      return 1
      ;;
  esac
}

agent_select_tool_exposure() {
  case "$1" in
    full|staged)
      ZCODER_TOOL_EXPOSURE="$1"
      REPLY=""
      return 0
      ;;
    *)
      REPLY="tool exposure must be full or staged"
      return 1
      ;;
  esac
}

agent_tool_is_admitted() {
  local name="$1" effect=""
  case "${AGENT_TOOL_PHASE:-full}" in
    full|external) return 0 ;;
    workspace)
      case "$name" in
        list_agents|send_agent_message) return 1 ;;
        mcp__*)
          if (( $+functions[mcp_tool_effect] )); then
            mcp_tool_effect "$name"
            effect="$REPLY"
            [[ "$effect" != external_write ]]
            return $?
          fi
          return 1
          ;;
        *) return 0 ;;
      esac
      ;;
    routing) return 1 ;;
    *) return 1 ;;
  esac
}


# Format the user-visible transcript independently from the tool result stored
# in AGENT_MESSAGES. Read and MCP bodies remain available to the model but do
# not flood the user's screen; edits remain visible for review.
agent_format_tool_ui_result() {
  local tool_name="$1" args_json="$2" result="$3"
  local -i succeeded="${4:-0}"
  local path="" start="" end="" content="" label=""
  if [[ "$tool_name" == mcp__* ]]; then
    transcript_tool_label "$tool_name"
    return 0
  fi
  if ! json_parse_flat_object "$args_json"; then
    (( succeeded )) && label="✓ ${tool_name}" || label="✗ ${tool_name}"
    REPLY="$label"$'\n'"$result"
    return 0
  fi
  zcoder_display_path "${JSON_OBJECT[path]:-?}"; path="$REPLY"
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
    replace_text)
      label="Replace Text(${path})"
      ;;
    apply_patch)
      content="${JSON_OBJECT[patch]:-}"
      label="Apply Patch"$'\n'"$content"
      ;;
    activate_skill)
      label="Skill(${JSON_OBJECT[name]:-?})"
      (( succeeded )) && { REPLY="$label"; return 0; }
      ;;
    read_skill_resource)
      label="Skill Resource(${JSON_OBJECT[name]:-?}:${JSON_OBJECT[path]:-?})"
      (( succeeded )) && { REPLY="$label"; return 0; }
      ;;
    run_command)
      if [[ "${JSON_OBJECT[user_initiated]:-}" == true ]]; then
        label="! ${JSON_OBJECT[command]}"$'\n'"Working directory: ${JSON_OBJECT[cwd]}"
      else
        label="$tool_name $args_json"
      fi
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
    AGENT_FINISH_ERROR="invalid finish arguments: ${ZJSON_ERROR:-parse error}"
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

agent_accounting_reset() {
  AGENT_ACCOUNTING_MESSAGES=(); AGENT_ACCOUNTING_BYTES=(); AGENT_ACCOUNTING_REASONING_BYTES=()
  AGENT_ACCOUNTING_CACHE_BYTES=0
}

_agent_accounting_cache_record() {
  local -i index=$1 bytes=$3 reasoning_bytes=$4
  (( ${#AGENT_ACCOUNTING_MESSAGES} )) || AGENT_ACCOUNTING_CACHE_BYTES=0
  (( index <= AGENT_ACCOUNTING_MAX_RECORDS )) || return 0
  if [[ -n "${AGENT_ACCOUNTING_MESSAGES[index]:-}" ]]; then
    (( AGENT_ACCOUNTING_CACHE_BYTES -= AGENT_ACCOUNTING_BYTES[index] ))
    AGENT_ACCOUNTING_MESSAGES[index]=''
    AGENT_ACCOUNTING_BYTES[index]=0; AGENT_ACCOUNTING_REASONING_BYTES[index]=0
  fi
  (( bytes <= AGENT_ACCOUNTING_MAX_RECORD_BYTES &&
      AGENT_ACCOUNTING_CACHE_BYTES + bytes <= AGENT_ACCOUNTING_MAX_CACHE_BYTES )) || return 0
  AGENT_ACCOUNTING_MESSAGES[index]="$2"
  AGENT_ACCOUNTING_BYTES[index]=$bytes
  AGENT_ACCOUNTING_REASONING_BYTES[index]=$reasoning_bytes
  (( AGENT_ACCOUNTING_CACHE_BYTES += bytes ))
  return 0
}

agent_reset() {
  AGENT_MESSAGES=()
  agent_accounting_reset
  AGENT_LAST_RESPONSE=""
  TOOL_PATCH_RETRY_REQUIRED=0
  (( $+functions[skills_reset_activations] )) && skills_reset_activations
  agent_loop_reset
  agent_compaction_reset
  (( $+functions[goal_reset] )) && goal_reset
}

agent_loop_reset() {
  AGENT_LOOP_WARNING_ACTIVE=0
  AGENT_LOOP_NUDGE=""
  AGENT_LOOP_REASON=""
  AGENT_LOOP_FORBIDDEN_REQUEST=""
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
  zjson_quote "$role"; role_json="$REPLY"
  zjson_quote "$content"; content_json="$REPLY"
  if [[ -n "$tool_name" ]]; then
    zjson_quote "$tool_name"; tool_json="$REPLY"
    AGENT_MESSAGES+=("{\"role\":${role_json},\"tool_name\":${tool_json},\"content\":${content_json}}")
  else
    AGENT_MESSAGES+=("{\"role\":${role_json},\"content\":${content_json}}")
  fi
  [[ "$role" == user ]] && AGENT_USER_MESSAGES+=("$content")
  agent_context_refresh_estimate
}

# Ollama model templates commonly require the system message to be the first
# and only system-role record. Harness-generated context added after a turn
# therefore travels as a user-role record, but is deliberately excluded from
# AGENT_USER_MESSAGES: that ledger contains only the user's exact requests.
agent_add_context_message() {
  local content="$1" content_json=""
  zjson_quote "$content"; content_json="$REPLY"
  AGENT_MESSAGES+=("{\"role\":\"user\",\"content\":${content_json}}")
  agent_context_refresh_estimate
}

# Sessions written by older releases may contain mid-conversation system
# records (notably delegated-consultant results and retry instructions).
# Normalize those records at the transport boundary so resuming an existing
# session cannot violate a strict Ollama chat template.
agent_history_payload_json() {
  local message=""
  local -a transport_messages=()
  local -i start=${1:-1}
  for message in "${(@)AGENT_MESSAGES[start,-1]}"; do
    # Queue receipts are local persistence metadata, not model API fields.
    if [[ "$message" == *',"input_id":"'*'"}' ]]; then
      message="${message%,\"input_id\":*}}"
    fi
    if [[ "$message" == '{"role":"system",'* ]]; then
      message='{"role":"user",'"${message#\{\"role\":\"system\",}"
    fi
    transport_messages+=("$message")
  done
  REPLY="${(j:,:)transport_messages}"
}

agent_add_assistant_message() {
  local content="$1" thinking="$2" tool_calls="$3"
  local content_json="" thinking_json="" message=""
  zjson_quote "$content"; content_json="$REPLY"
  message="{\"role\":\"assistant\",\"content\":${content_json}"
  if [[ -n "$thinking" ]]; then
    zjson_quote "$thinking"; thinking_json="$REPLY"
    message+=",\"thinking\":${thinking_json}"
  fi
  [[ "$tool_calls" != "[]" ]] && message+=",\"tool_calls\":${tool_calls}"
  AGENT_MESSAGES+=("${message}}")
  # Creation already owns escaped reasoning. Seed only bounded records;
  # retaining a second copy of a large response would outweigh this shortcut.
  local -i index=${#AGENT_MESSAGES} message_bytes reasoning_bytes=0
  _http_byte_length "${AGENT_MESSAGES[index]}"; message_bytes=$REPLY
  if (( message_bytes <= AGENT_ACCOUNTING_MAX_RECORD_BYTES && index <= AGENT_ACCOUNTING_MAX_RECORDS )); then
    if [[ -n "$thinking" ]]; then
      _http_byte_length "$thinking_json"; reasoning_bytes=$REPLY
    fi
    _agent_accounting_cache_record "$index" "${AGENT_MESSAGES[index]}" "$message_bytes" "$reasoning_bytes"
  fi
  agent_context_refresh_estimate
}

agent_system_prompt_parts() {
  # Ordered reply fields: base, project, skills, MCP, relay, checkpoint,
  # completion rules, goal, loop guidance. Payloads and accounting share this
  # assembly to keep inspection aligned with the guidance sent to the model.
  local base="$AGENT_SYSTEM_PROMPT" project='' skills='' mcp='' relay='' checkpoint=''
  local completion='' goal='' loop='' routing_instructions=''
  if (( ${GOAL_VERIFIER_ACTIVE:-0} )) && (( $+functions[goal_verifier_system_prompt] )); then
    goal_verifier_system_prompt
    reply=("$REPLY" '' '' '' '' '' '' '' '')
    return 0
  fi
  if [[ "${AGENT_TOOL_PHASE:-full}" == routing ]]; then
    agent_routing_system_prompt
    routing_instructions="$REPLY"
    if [[ -n "$base" ]]; then
      base+=$'\n\n<tool_routing>\n'"${routing_instructions}"$'\n</tool_routing>'
    else
      base="$routing_instructions"
    fi
  else
    [[ -n "$base" ]] || { agent_default_system_prompt; base="$REPLY"; }
    agent_lfm_prompt_block
    base+="$REPLY"
  fi
  if (( $+functions[instructions_prompt_block] )); then
    instructions_prompt_block
    project="$REPLY"
  fi
  if [[ "${AGENT_TOOL_PHASE:-full}" == routing ]] && (( $+functions[skills_active_prompt_block] )); then
    skills_active_prompt_block
    skills="$REPLY"
  elif (( $+functions[skills_prompt_block] )); then
    skills_prompt_block
    skills="$REPLY"
  fi
  if (( $+functions[mcp_prompt_block] )) && [[ "${AGENT_TOOL_PHASE:-full}" != routing ]]; then
    mcp_prompt_block
    mcp="$REPLY"
  fi
  if (( $+functions[relay_prompt_block] )) && [[ "${AGENT_TOOL_PHASE:-full}" == full || "${AGENT_TOOL_PHASE:-full}" == external ]]; then
    relay_prompt_block
    relay="$REPLY"
  fi
  if (( $+functions[agent_compaction_prompt_block] )); then
    agent_compaction_prompt_block
    checkpoint="$REPLY"
  fi
  if (( $+functions[instructions_completion_block] )); then
    instructions_completion_block
    completion="$REPLY"
  fi
  if (( $+functions[goal_prompt_block] )); then
    goal_prompt_block
    goal="$REPLY"
  fi
  [[ -n "$AGENT_LOOP_NUDGE" ]] && loop=$'\n\n'"$AGENT_LOOP_NUDGE"
  reply=("$base" "$project" "$skills" "$mcp" "$relay" "$checkpoint" "$completion" "$goal" "$loop")
}

agent_resolve_system_prompt() {
  local -a reply=()
  agent_system_prompt_parts
  REPLY="${(j::)reply}"
}

# Preserve connection cancellation through payload preparation. Serializers
# must not turn a cancelled catalog into a model request with missing tools.
agent_tools_schema_json() {
  tools_schema_json
  local -i schema_status=$?
  if (( schema_status != 0 )); then
    (( schema_status == 130 )) && AGENT_CANCELLED=1
    HTTP_ERROR="${MCP_ERROR:-Tool catalog preparation stopped}"
    REPLY=''
  fi
  return "$schema_status"
}

agent_build_payload() {
  local model_json="" system_json="" messages="[" history="" think="true" tools="" options="" prompt="" format=""
  local stream=false
  [[ "${1:-false}" == true ]] && stream=true
  # MCP discovery must precede prompt assembly. Besides producing Ollama's
  # schemas, it gives small models an exact short-name -> function-name map.
  if (( $# >= 2 )); then
    tools="$2"
  else
    agent_tools_schema_json || return $?
    tools="$REPLY"
    AGENT_CONTEXT_TOOLS="$tools"
  fi
  agent_resolve_system_prompt
  prompt="$REPLY"
  zjson_quote "$ZCODER_MODEL"; model_json="$REPLY"
  zjson_quote "$prompt"; system_json="$REPLY"
  messages+="{\"role\":\"system\",\"content\":${system_json}}"
  # Join at C speed; appending message by message re-copies the growing
  # payload and is quadratic for long histories.
  if (( ${#AGENT_MESSAGES} > 0 )); then
    agent_history_payload_json
    history="$REPLY"
    messages+=",${history}"
  fi
  messages+="]"
  agent_context_options_json
  options="$REPLY"
  if [[ "${AGENT_TOOL_PHASE:-full}" == routing ]]; then
    agent_route_schema_json
    format="$REPLY"
    REPLY="{\"model\":${model_json},\"messages\":${messages},\"format\":${format},\"stream\":false,\"think\":false,\"options\":{${options}\"num_predict\":${ZCODER_MAX_OUTPUT_TOKENS}}}"
    return 0
  fi
  [[ "$ZCODER_THINK" == true || "$ZCODER_THINK" == false ]] || think="false"
  [[ "$ZCODER_THINK" == false ]] && think="false"
  REPLY="{\"model\":${model_json},\"messages\":${messages},\"tools\":${tools},\"stream\":${stream},\"think\":${think},\"options\":{${options}\"num_predict\":${ZCODER_MAX_OUTPUT_TOKENS}}}"
}

agent_context_refresh_estimate() {
  # Message/skill changes must reach the status counter before the next
  # request. Reuse the last tool catalog: accounting must never connect MCP
  # servers or enter an input loop. The next real request refreshes schemas.
  [[ -n "$AGENT_CONTEXT_TOOLS" ]] || return 0
  local REPLY=''
  agent_build_payload false "$AGENT_CONTEXT_TOOLS" || return $?
  agent_estimate_payload_tokens "$REPLY"
}

agent_context_component_tokens() {
  _http_byte_length "$1"
  agent_context_component_byte_tokens "$REPLY"
}

agent_context_component_byte_tokens() {
  local -i bytes=$1 estimate
  if (( AGENT_LAST_PROMPT_TOKENS > 0 && AGENT_LAST_PAYLOAD_BYTES > 0 )); then
    estimate=$(( (bytes * AGENT_LAST_PROMPT_TOKENS * 110 + AGENT_LAST_PAYLOAD_BYTES * 100 - 1) / (AGENT_LAST_PAYLOAD_BYTES * 100) ))
  else
    estimate=$(( (bytes + 2) / 3 ))
  fi
  REPLY="$estimate"
}

# Attribute estimated prompt tokens to model-visible components. This is an
# operational estimate for finding bloat, not provider billing evidence.
agent_context_bill() {
  zjson_with_context _agent_context_bill "$@"
}

_agent_context_bill() {
  setopt localoptions extendedglob nonomatch
  local base="" instructions="" skills="" mcp="" compacted="" tools="" message=""
  local relay='' goal='' loop=''
  local -a reply=()
  local -i base_tokens=0 instruction_tokens=0 skill_tokens=0 mcp_tokens=0
  local -i relay_tokens=0 goal_tokens=0 loop_tokens=0
  local -i compacted_tokens=0 tool_schema_tokens=0 user_tokens=0 assistant_tokens=0 tool_result_tokens=0 reasoning_tokens=0 skill_resource_tokens=0 message_tokens=0
  # Inspector parsing must not overwrite a response still owned by the turn.
  local JSON_RESPONSE_CONTENT='' JSON_RESPONSE_THINKING='' JSON_RESPONSE_ERROR='' JSON_RESPONSE_TOOL_CALLS=''
  local -a JSON_TOOL_NAMES=() JSON_TOOL_ARGS=()
  local -i JSON_RESPONSE_DONE=-1 JSON_RESPONSE_PROMPT_TOKENS=0 JSON_RESPONSE_OUTPUT_TOKENS=0
  local -i index=0 reasoning_bytes=0 message_bytes=0 removed=0

  agent_system_prompt_parts
  base=$reply[1]; instructions="$reply[2]$reply[7]"; skills=$reply[3]
  mcp=$reply[4]; relay=$reply[5]; compacted=$reply[6]; goal=$reply[8]; loop=$reply[9]
  if [[ "${AGENT_TOOL_PHASE:-full}" == routing ]]; then
    agent_route_schema_json; tools="$REPLY"
  else
    # Inspection is observational: use the catalog from payload preparation,
    # never start MCP discovery or another UI input loop here.
    tools="${AGENT_CONTEXT_TOOLS:-[]}"
  fi

  agent_context_component_tokens "$base"; base_tokens=$REPLY
  agent_context_component_tokens "$instructions"; instruction_tokens=$REPLY
  agent_context_component_tokens "$skills"; skill_tokens=$REPLY
  agent_context_component_tokens "$mcp"; mcp_tokens=$REPLY
  agent_context_component_tokens "$compacted"; compacted_tokens=$REPLY
  agent_context_component_tokens "$relay"; relay_tokens=$REPLY
  agent_context_component_tokens "$goal"; goal_tokens=$REPLY
  agent_context_component_tokens "$loop"; loop_tokens=$REPLY
  agent_context_component_tokens "$tools"; tool_schema_tokens=$REPLY
  for message in "${AGENT_MESSAGES[@]}"; do
    (( index++ ))
    if [[ "${AGENT_ACCOUNTING_MESSAGES[index]:-}" == "$message" ]]; then
      (( message_bytes = AGENT_ACCOUNTING_BYTES[index], reasoning_bytes = AGENT_ACCOUNTING_REASONING_BYTES[index] ))
    else
      _http_byte_length "$message"; message_bytes=$REPLY
      reasoning_bytes=0
      if [[ "$message" == '{"role":"assistant",'* && "$message" == *',"thinking":'* ]] &&
          json_parse_ollama_response '{"message":'"$message"'}' && [[ -n "$JSON_RESPONSE_THINKING" ]]; then
        zjson_quote "$JSON_RESPONSE_THINKING"
        _http_byte_length "$REPLY"; reasoning_bytes=$REPLY
      fi
      _agent_accounting_cache_record "$index" "$message" "$message_bytes" "$reasoning_bytes"
    fi
    agent_context_component_byte_tokens "$message_bytes"
    message_tokens=$REPLY
    case "$message" in
      '{"role":"tool","tool_name":"read_skill_resource",'*) (( skill_resource_tokens += message_tokens )) ;;
      '{"role":"tool","tool_name":"activate_skill",'*) (( skill_tokens += message_tokens )) ;;
      '{"role":"tool",'*) (( tool_result_tokens += REPLY )) ;;
      '{"role":"assistant",'*)
        # Split the existing estimate rather than counting thinking twice.
        if (( reasoning_bytes > 0 )); then
          agent_context_component_byte_tokens "$reasoning_bytes"
          (( reasoning_tokens += REPLY, message_tokens -= REPLY ))
        fi
        (( assistant_tokens += message_tokens )) ;;
      *) (( user_tokens += REPLY )) ;;
    esac
  done
  if (( ${#AGENT_ACCOUNTING_MESSAGES} > index )); then
    for (( removed=index+1; removed<=${#AGENT_ACCOUNTING_MESSAGES}; removed++ )); do
      (( AGENT_ACCOUNTING_CACHE_BYTES -= ${AGENT_ACCOUNTING_BYTES[removed]:-0} ))
    done
    AGENT_ACCOUNTING_MESSAGES[index+1,-1]=()
    AGENT_ACCOUNTING_BYTES[index+1,-1]=()
    AGENT_ACCOUNTING_REASONING_BYTES[index+1,-1]=()
  fi
  AGENT_CONTEXT_COMPONENT_LABELS=("Base guidance" "Project instructions" "Skills" "MCP guidance" "Checkpoint" "Tool schemas" "User/context" "Assistant" "Tool results" "Reasoning" "Skill resources" "Relay guidance" "Goal guidance" "Loop guidance")
  AGENT_CONTEXT_COMPONENT_VALUES=("$base_tokens" "$instruction_tokens" "$skill_tokens" "$mcp_tokens" "$compacted_tokens" "$tool_schema_tokens" "$user_tokens" "$assistant_tokens" "$tool_result_tokens" "$reasoning_tokens" "$skill_resource_tokens" "$relay_tokens" "$goal_tokens" "$loop_tokens")
  REPLY="Estimated context bill: base=${base_tokens}; project=${instruction_tokens}; skills=${skill_tokens}; mcp=${mcp_tokens}; checkpoint=${compacted_tokens}; tool schemas=${tool_schema_tokens}; user/context=${user_tokens}; assistant=${assistant_tokens}; tool results=${tool_result_tokens}; reasoning=${reasoning_tokens}; skill resources=${skill_resource_tokens}; relay=${relay_tokens}; goal=${goal_tokens}; loop=${loop_tokens}."
}

# Build a disposable request whose prefix matches a normal agent request while
# excluding conversation history. It loads the selected runner and gives
# Ollama an opportunity to cache the stable system/tool prefix. The synthetic
# exchange is never added to AGENT_MESSAGES or persistent session state.
agent_build_warmup_payload() {
  local model_json="" system_json="" user_json="" tools="" options="" prompt="" format=""
  local AGENT_TOOL_PHASE="full"
  [[ "$ZCODER_TOOL_EXPOSURE" == staged ]] && AGENT_TOOL_PHASE="routing"
  agent_context_configure || return $?
  agent_tools_schema_json || return $?
  tools="$REPLY"
  agent_resolve_system_prompt
  prompt="$REPLY"
  zjson_quote "$ZCODER_MODEL"; model_json="$REPLY"
  zjson_quote "$prompt"; system_json="$REPLY"
  if [[ "$AGENT_TOOL_PHASE" == routing ]]; then
    zjson_quote "Initialization check only. Return the routing object with mode respond, response Ready, and an empty reason."; user_json="$REPLY"
  else
    zjson_quote "Initialization check only. Do not call tools. After reading all instructions and context, respond with exactly Ready and nothing else."; user_json="$REPLY"
  fi
  agent_context_options_json
  options="$REPLY"
  if [[ "$AGENT_TOOL_PHASE" == routing ]]; then
    agent_route_schema_json
    format="$REPLY"
    REPLY="{\"model\":${model_json},\"messages\":[{\"role\":\"system\",\"content\":${system_json}},{\"role\":\"user\",\"content\":${user_json}}],\"format\":${format},\"stream\":false,\"think\":false,\"options\":{${options}\"num_predict\":64,\"temperature\":0}}"
    return 0
  fi
  REPLY="{\"model\":${model_json},\"messages\":[{\"role\":\"system\",\"content\":${system_json}},{\"role\":\"user\",\"content\":${user_json}}],\"tools\":${tools},\"stream\":false,\"think\":false,\"options\":{${options}\"num_predict\":8,\"temperature\":0}}"
}

agent_warmup_enabled() {
  [[ "$ZCODER_WARMUP" == true && "${REMOTE_MODE:-local}" == local && ${UI_ACTIVE:-0} -eq 1 ]]
}

agent_warmup_cancel() {
  local reason="${1:-warm-up superseded}"
  (( AGENT_WARMUP_ACTIVE )) || return 0
  zcoder_debug warmup_cancel "model=${(qqq)AGENT_WARMUP_MODEL} host=${(qqq)AGENT_WARMUP_HOST} reason=${(qqq)reason}"
  http_async_cancel "$reason"
  AGENT_WARMUP_ACTIVE=0
  AGENT_WARMUP_MODEL=""
  AGENT_WARMUP_HOST=""
  agent_set_status "Ready"
}

agent_warmup_start() {
  local payload=""
  agent_warmup_enabled || return 0
  (( AGENT_WARMUP_ACTIVE )) && agent_warmup_cancel "warm-up restarted"
  agent_set_status "Warming Up"
  agent_build_warmup_payload || {
    local -i preparation_status=$?
    agent_set_status "Warm-up stopped"
    return "$preparation_status"
  }
  payload="$REPLY"
  if ! http_async_start POST /api/chat "$payload" "$OLLAMA_HOST"; then
    zcoder_debug warmup_start_error "model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} error=${(qqq)HTTP_ERROR}"
    agent_set_status "Warm-up Failed"
    return 1
  fi
  AGENT_WARMUP_ACTIVE=1
  AGENT_WARMUP_MODEL="$ZCODER_MODEL"
  AGENT_WARMUP_HOST="$OLLAMA_HOST"
  zcoder_debug warmup_start "model=${(qqq)AGENT_WARMUP_MODEL} host=${(qqq)AGENT_WARMUP_HOST} payload_chars=${#payload}"
  return 0
}

agent_warmup_collect() {
  local response="" content="" error=""
  local -i request_status=0 parse_status=0
  (( AGENT_WARMUP_ACTIVE )) || return 0
  http_async_ready || return 1
  http_async_collect
  request_status=$?
  response="$HTTP_BODY"
  AGENT_WARMUP_ACTIVE=0
  if (( request_status == 0 )); then
    json_parse_ollama_response "$response" || parse_status=$?
  fi
  if (( request_status == 0 && parse_status == 0 )) && [[ -z "$JSON_RESPONSE_ERROR" ]]; then
    content="$JSON_RESPONSE_CONTENT"
    agent_context_refresh_after_response
    zcoder_debug warmup_complete "model=${(qqq)AGENT_WARMUP_MODEL} host=${(qqq)AGENT_WARMUP_HOST} response=${(qqq)content}"
    AGENT_WARMUP_MODEL=""
    AGENT_WARMUP_HOST=""
    agent_set_status "Ready"
    return 0
  fi
  if (( request_status != 0 )); then
    error="${HTTP_ERROR:-Ollama warm-up request failed}"
  elif (( parse_status != 0 )); then
    error="${ZJSON_ERROR:-invalid Ollama warm-up response}"
  else
    error="${JSON_RESPONSE_ERROR:-Ollama warm-up failed}"
  fi
  zcoder_debug warmup_error "model=${(qqq)AGENT_WARMUP_MODEL} host=${(qqq)AGENT_WARMUP_HOST} status=$request_status error=${(qqq)error}"
  AGENT_WARMUP_MODEL=""
  AGENT_WARMUP_HOST=""
  agent_set_status "Warm-up Failed"
  return 1
}

agent_warmup_poll() {
  (( AGENT_WARMUP_ACTIVE )) || return 0
  http_async_ready || return 0
  agent_warmup_collect || true
}

# LFM sometimes puts private reasoning or a competing JSON action envelope in
# message.content even when Ollama also returned native tool_calls. Keep the
# native calls authoritative and move that incidental content into the
# collapsible thinking channel. A leading <think> block is also separated from
# a tool-free final answer so it is never printed as user-facing prose.

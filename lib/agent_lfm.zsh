# LFM-specific response normalization and conservative JSON recovery.

agent_normalize_lfm_response() {
  local content="$1" thinking="$2" prefix="" remainder="" thought=""
  local -i has_native_tools="${3:-0}"
  AGENT_NORMALIZED_CONTENT="$content"
  AGENT_NORMALIZED_THINKING="$thinking"
  [[ "${(L)ZCODER_MODEL:t}" == *lfm* ]] || return 0

  if [[ "$content" == *'<think>'*'</think>'* ]]; then
    prefix="${content%%'<think>'*}"
    if [[ -z "${prefix//[[:space:]]/}" ]]; then
      remainder="${content#*'<think>'}"
      thought="${remainder%%'</think>'*}"
      content="${remainder#*'</think>'}"
      content="${content#"${content%%[![:space:]]*}"}"
      if [[ -n "$thought" ]]; then
        [[ -n "$thinking" ]] && thinking+=$'\n\n'
        thinking+="$thought"
      fi
    fi
  fi

  if (( has_native_tools )) && [[ -n "$content" ]]; then
    [[ -n "$thinking" ]] && thinking+=$'\n\n'
    thinking+="$content"
    content=""
  fi
  AGENT_NORMALIZED_CONTENT="$content"
  AGENT_NORMALIZED_THINKING="$thinking"
}

_agent_content_is_lfm_json_plan() {
  local content="$1" model="${(L)ZCODER_MODEL:t}" key=""
  local -i has_plan=0 has_context=0 has_next_action=0
  [[ "$model" == *lfm* ]] || return 1
  zjson_begin "$content" || return 1
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || return 1
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
    key="$ZJSON_TOKEN_VALUE"
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
    zjson_next || return 1
    if [[ "$key" == commands && "$ZJSON_TOKEN_TYPE" == '[' ]]; then
      zjson_next || return 1
      while [[ "$ZJSON_TOKEN_TYPE" != ']' ]]; do
        has_next_action=1
        zjson_discard_value || return 1
        if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
          zjson_next || return 1
          [[ "$ZJSON_TOKEN_TYPE" != ']' ]] || { _json_trailing_comma; return 1; }
        elif [[ "$ZJSON_TOKEN_TYPE" != ']' ]]; then
          return 1
        fi
      done
      zjson_next || return 1
    else
      case "$key:$ZJSON_TOKEN_TYPE" in
        plan:string) has_plan=1 ;;
        analysis:string|observations:string|observations:'['|steps:string|steps:'[') has_context=1 ;;
        instructions:string|check:string|turn_control:string)
          has_context=1
          has_next_action=1
          ;;
        next_steps:'['|next_step:string|next\ actions:string|actions:'['|tool_calls:'['|tool_call:'{')
          has_next_action=1
          ;;
      esac
      zjson_discard_value || return 1
    fi
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
      [[ "$ZJSON_TOKEN_TYPE" != '}' ]] || { _json_trailing_comma; return 1; }
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == eof ]] || return 1
  (( has_plan && has_context && has_next_action ))
}

agent_content_is_lfm_intermediate_plan() {
  local content="$1" model="${(L)ZCODER_MODEL:t}" compact=""
  local -i has_next_action=0
  [[ "$model" == *lfm* ]] || return 1
  # Some LFM templates leak the opening control marker into content without
  # producing Ollama's native tool_calls field. It is an unfinished action,
  # never a user-facing final answer.
  [[ "$content" == *'<|tool_call>'* || "$content" == *'<|tool_call|>'* ]] && return 0
  _agent_content_is_lfm_json_plan "$content" && return 0
  # A one-member string object is the stable structural core of LFM's
  # free-form planner labels (for example "First action"). JSON-only user
  # requests are excluded by the caller before this classification is used.
  _agent_lfm_json_is_single_string_object "$content" && return 0
  _agent_scan_lfm_balanced_objects "$content"
  (( AGENT_LFM_BALANCED_PLAN_OBJECTS > 0 || AGENT_LFM_BALANCED_CALL_OBJECTS > 0 )) && return 0
  # Some LFM turns place literal newlines inside quoted shell commands. The
  # inner planner envelope is then invalid JSON even though Ollama's outer
  # response is valid. Recognize that model-specific shape only for a retry;
  # malformed content is never promoted to a tool call.
  compact="${content//[[:space:]]/}"
  [[ "$compact" == \{* && "$compact" == *'"plan":'* ]] || return 1
  [[ "$compact" == *'"analysis":'* || "$compact" == *'"instructions":'* || \
     "$compact" == *'"observations":'* || "$compact" == *'"steps":'* ]] || return 1
  [[ "$compact" == *'"commands":'* && "$compact" != *'"commands":[]'* ]] && has_next_action=1
  [[ "$compact" == *'"actions":'* && "$compact" != *'"actions":[]'* ]] && has_next_action=1
  [[ "$compact" == *'"next_steps":'* && "$compact" != *'"next_steps":[]'* ]] && has_next_action=1
  [[ "$compact" == *'"next_step":'* ]] && has_next_action=1
  [[ "$compact" == *'"next actions":'* ]] && has_next_action=1
  [[ "$compact" == *'"tool_calls":'* && "$compact" != *'"tool_calls":[]'* ]] && has_next_action=1
  [[ "$compact" == *'"tool_call":{'* ]] && has_next_action=1
  [[ "$compact" == *'"turn_control":'* ]] && has_next_action=1
  (( has_next_action ))
}

agent_content_is_lfm_false_tool_refusal() {
  local model="${(L)ZCODER_MODEL:t}" content="${(L)1}"
  [[ "$model" == *lfm* ]] || return 1
  [[ "$content" == *'file system tools'*'not available'* || \
     "$content" == *'filesystem tools'*'not available'* || \
     "$content" == *'tools, which are not available'* || \
     "$content" == *'tools are not available in my current capabilities'* || \
     "$content" == *'do not have access to the provided tools'* || \
     "$content" == *'cannot access the provided tools'* ]]
}

agent_content_is_lfm_false_path_conclusion() {
  local model="${(L)ZCODER_MODEL:t}" prior="" request=""
  [[ "$model" == *lfm* && ${#AGENT_MESSAGES} -ge 2 && ${#AGENT_USER_MESSAGES} -gt 0 ]] || return 1
  prior="${AGENT_MESSAGES[-2]}"
  request="${(L)AGENT_USER_MESSAGES[-1]}"
  [[ "$prior" == *'search examines file contents, not filenames; use list_files to discover file paths.'* ]] || return 1
  [[ "$request" == *'find '* || "$request" == *'locate '* ||
     "$request" == *'inspect the workspace'* || "$request" == *'file path'* ]]
}

agent_lfm_user_requests_plan_only() {
  local content="${(L)1}"
  [[ "$content" == *'do not execute'* || "$content" == *"don't execute"* || \
     "$content" == *'without executing'* || "$content" == *'plan only'* || \
     "$content" == *'only provide a plan'* || "$content" == *'just provide a plan'* || \
     "$content" == *'respond with json'* || "$content" == *'return only json'* ]]
}

_agent_lfm_json_is_call_object() {
  local candidate="$1" key=""
  local -i call_members=0
  zjson_begin "$candidate" || return 1
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || return 1
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
    key="$ZJSON_TOKEN_VALUE"
    [[ "$key" == name || "$key" == tool_name || "$key" == arguments ]] && (( call_members++ ))
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
    zjson_next || return 1
    zjson_discard_value || return 1
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
      [[ "$ZJSON_TOKEN_TYPE" != '}' ]] || { _json_trailing_comma; return 1; }
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == eof ]] || return 1
  (( call_members > 0 ))
}

# Inspect every complete object delimited by balanced braces. Quotes and
# escapes are tracked so braces in argument strings remain ordinary data. The
# surrounding text need not be valid JSON, but each candidate is parsed
# strictly and no candidate text is repaired. This scan only classifies a
# content response for a corrective retry; it never produces an executable
# action.
_agent_scan_lfm_balanced_objects() {
  local content="$1" ch="" candidate=""
  local -a chars=() starts=()
  local -i i start in_string=0 escaped=0 plan_objects=0 call_objects=0
  AGENT_LFM_BALANCED_PLAN_OBJECTS=0
  AGENT_LFM_BALANCED_CALL_OBJECTS=0
  [[ -n "$content" ]] && chars=("${(@s::)content}")
  for (( i=1; i<=${#chars}; i++ )); do
    ch="${chars[i]}"
    if (( in_string )); then
      if (( escaped )); then
        escaped=0
      elif [[ "$ch" == '\\' ]]; then
        escaped=1
      elif [[ "$ch" == '"' ]]; then
        in_string=0
      fi
      continue
    fi
    if [[ "$ch" == '"' ]]; then
      in_string=1
    elif [[ "$ch" == '{' ]]; then
      starts+=("$i")
    elif [[ "$ch" == '}' && ${#starts} -gt 0 ]]; then
      start="${starts[-1]}"
      starts[-1]=()
      candidate="${(j::)chars[start,i]}"
      if (( ${#starts} == 0 )) && _agent_lfm_json_is_single_string_object "$candidate"; then
        (( plan_objects++ ))
      fi
      _agent_lfm_json_is_call_object "$candidate" && (( call_objects++ ))
    fi
  done
  AGENT_LFM_BALANCED_PLAN_OBJECTS=$plan_objects
  AGENT_LFM_BALANCED_CALL_OBJECTS=$call_objects
}

_agent_lfm_json_is_single_string_object() {
  local content="$1"
  zjson_begin "$content" || return 1
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || return 1
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == '}' ]] || return 1
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == eof ]]
}

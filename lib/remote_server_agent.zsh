# Remote server integration with agent turns, sessions, and model preparation.

_remote_server_input_request() {
  local fd="$1" action="$2" session='' turn='' id='' mode='' text='' session_dir='' field=''
  local -a reply=()
  json_parse_flat_object "$REMOTE_REQUEST_BODY" || { _remote_http_error "$fd" 400 'invalid input request'; return; }
  for field in session_id turn_id message_id mode text; do
    if (( ${+JSON_OBJECT[$field]} )) && [[ "${JSON_OBJECT_TYPES[$field]}" != string ]]; then
      _remote_http_error "$fd" 400 "$field must be a string"; return
    fi
  done
  session="${JSON_OBJECT[session_id]:-}"
  turn="${JSON_OBJECT[turn_id]:-}"
  id="${JSON_OBJECT[message_id]:-}"
  mode="${JSON_OBJECT[mode]:-steer}"
  text="${JSON_OBJECT[text]:-}"
  session_dir="$ZCODER_SESSIONS_DIR/${session}.session"
  if ! _state_valid_id "$session" || [[ ! -d "$session_dir" ]] ||
      ! state_snapshot_values "$session_dir" workspace profile; then
    _remote_http_error "$fd" 404 'unknown session'; return
  fi
  if ! _state_scope_matches "${reply[1]}" "${reply[2]}"; then
    _remote_http_error "$fd" 404 'unknown session'; return
  fi
  if [[ "$session" != "$REMOTE_SESSION_ID" || ( ! -f "$REMOTE_RUNTIME_DIR/active.pid" && ! -f "$REMOTE_RUNTIME_DIR/pending_prompt" ) ]]; then
    # A server restart must not reopen admission for an abandoned worker.
    # Existing IDs can still retrieve their original receipt below.
    local CURRENT_SESSION_ID="$session" INPUT_QUEUE_TURN_ID="${mapfile[$session_dir/input_queue/active]:-}"
    input_queue_close true || true
  fi
  if input_queue_request "$action" "$session" "$turn" "$id" "$mode" "$text"; then
    _remote_http_send "$fd" 200 "$REPLY"
  else
    _remote_http_error "$fd" 409 "${INPUT_QUEUE_ERROR:-input queue operation failed}"
  fi
}

_remote_safe_name() {
  REPLY="${1//[^A-Za-z0-9_.-]/_}"
  [[ -n "$REPLY" ]] || REPLY="server"
}

_remote_server_publish_json() {
  local json="$1" event_dir="$REMOTE_RUNTIME_DIR/events" file="" tmp=""
  local -a files=()
  local -i seq=1
  files=("$event_dir"/*.json(N))
  if (( ${#files} > 0 )); then
    file="${files[-1]:t:r}"
    [[ "$file" == <0-> ]] && seq=$(( 10#$file + 1 ))
  fi
  printf -v file '%09d.json' "$seq"
  tmp="$event_dir/.${file}.${sysparams[pid]:-$$}.${RANDOM}"
  mapfile[$tmp]="$json" || return 1
  zf_mv -f "$tmp" "$event_dir/$file" 2>/dev/null || { zf_rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

remote_server_emit_message() {
  local role="$1" content="$2" thinking="${3:-}" role_json="" content_json="" thinking_json=""
  zjson_quote "$role"; role_json="$REPLY"
  zjson_quote "$content"; content_json="$REPLY"
  zjson_quote "$thinking"; thinking_json="$REPLY"
  _remote_server_publish_json "{\"event\":\"message\",\"role\":${role_json},\"content\":${content_json},\"thinking\":${thinking_json}}"
}

remote_server_emit_status() {
  local status_json=""
  zcoder_status_display_text "$1"
  zjson_quote "$REPLY"; status_json="$REPLY"
  _remote_server_publish_json "{\"event\":\"status\",\"status\":${status_json}}"
}

remote_server_worker_emit() {
  ui_append_message "$@"
  remote_server_emit_message "$@"
}

remote_server_worker_status() {
  remote_server_emit_status "$1"
}

remote_server_worker_tool_event() {
  local phase="$1" name="$2" args="{}" result="${4:-}" succeeded="${5:-0}"
  local id_json="" name_json="" args_json="" result_json="" diff="${6:-}" diff_json=''
  (( REMOTE_STRUCTURED_TOOL_EVENTS )) || return 0
  [[ -z "${3:-}" ]] || args="$3"
  case "$phase" in
    begin)
      (( REMOTE_SERVER_TOOL_SEQUENCE++ ))
      REMOTE_SERVER_TOOL_CALL_ID="tool_${REMOTE_TURN_ID}_${sysparams[pid]}_${REMOTE_SERVER_TOOL_SEQUENCE}"
      ;;
    running|complete) [[ -n "$REMOTE_SERVER_TOOL_CALL_ID" ]] || return 0 ;;
    *) return 0 ;;
  esac
  transcript_tool_event "$phase" "$name" "$args" "$result" "$succeeded" "$REMOTE_SERVER_TOOL_CALL_ID" "$diff"
  zjson_quote "$REMOTE_SERVER_TOOL_CALL_ID"; id_json="$REPLY"
  zjson_quote "$name"; name_json="$REPLY"
  zjson_quote "$args"; args_json="$REPLY"
  zjson_quote "$result"; result_json="$REPLY"
  zjson_quote "$diff"; diff_json="$REPLY"
  _remote_server_publish_json "{\"event\":\"tool\",\"phase\":\"${phase}\",\"tool_call_id\":${id_json},\"name\":${name_json},\"args\":${args_json},\"result\":${result_json},\"succeeded\":${succeeded},\"diff\":${diff_json}}"
  [[ "$phase" == complete ]] && REMOTE_SERVER_TOOL_CALL_ID=""
  return 0
}

_remote_server_model_status_json() {
  local status_json="" error_json=""
  zjson_quote "$REMOTE_MODEL_STATUS"; status_json="$REPLY"
  zjson_quote "$REMOTE_MODEL_ERROR"; error_json="$REPLY"
  REPLY="{\"model_status\":${status_json},\"model_error\":${error_json}}"
  _remote_server_git_json
}

# Add current server workspace metadata to a flat protocol-1 response. Older
# peers ignore the optional field; new clients never inspect local remote paths.
_remote_server_git_json() {
  local response="$REPLY"
  zcoder_git_status "$ZCODER_WORKSPACE"
  zjson_quote "$REPLY"
  REPLY="${response%\}},\"git_status\":${REPLY}}"
}

_remote_server_model_poll() {
  local response="" error="" kind="$REMOTE_MODEL_REQUEST_KIND"
  local -i request_status=0 parse_status=0
  [[ "$REMOTE_MODEL_STATUS" == warming ]] || return 0
  if (( EPOCHREALTIME >= REMOTE_MODEL_DEADLINE )); then
    http_async_cancel
    REMOTE_MODEL_REQUEST_KIND=''
    REMOTE_MODEL_STATUS=error
    REMOTE_MODEL_ERROR='Ollama model preparation timed out'
    return 2
  fi
  http_async_ready || return 1
  http_async_collect
  request_status=$?
  response="$HTTP_BODY"
  REMOTE_MODEL_REQUEST_KIND=''
  if (( request_status == 0 )) && [[ "$kind" == check || "$kind" == refresh ]]; then
    if ! json_parse_running_model_context "$response" "$ZCODER_MODEL"; then
      error="could not parse Ollama running-model list: ${ZJSON_ERROR:-invalid JSON}"
    elif (( JSON_RUNNING_MODEL_CONTEXT > 0 )); then
      AGENT_CONTEXT_WINDOW=$JSON_RUNNING_MODEL_CONTEXT
      AGENT_CONTEXT_MODEL="$ZCODER_MODEL"
      AGENT_CONTEXT_DISCOVERY_PENDING=0
      REMOTE_MODEL_STATUS=ready
      REMOTE_MODEL_ERROR=''
      return 0
    elif [[ "$kind" == check ]]; then
      _remote_server_model_start_warmup || return 2
      return 1
    else
      error='configured model is not resident after warm-up'
    fi
    REMOTE_MODEL_STATUS=error
    REMOTE_MODEL_ERROR="$error"
    return 2
  fi
  if (( request_status == 0 )); then
    json_parse_ollama_response "$response" || parse_status=$?
  fi
  if (( request_status == 0 && parse_status == 0 )) && [[ -z "$JSON_RESPONSE_ERROR" ]]; then
    _remote_server_model_start_check refresh || return 2
    return 1
  fi
  if (( request_status != 0 )); then
    error="${HTTP_ERROR:-Ollama warm-up request failed}"
  elif (( parse_status != 0 )); then
    error="${ZJSON_ERROR:-invalid Ollama warm-up response}"
  else
    error="${JSON_RESPONSE_ERROR:-Ollama warm-up failed}"
  fi
  REMOTE_MODEL_STATUS="error"
  REMOTE_MODEL_ERROR="$error"
  zcoder_debug remote_warmup_error "model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} status=$request_status error=${(qqq)error}"
  return 2
}

_remote_server_model_start_check() {
  local kind="${1:-check}" connection_fd="${2:-}"
  if ! http_async_start GET /api/ps '' "$OLLAMA_HOST" "$REMOTE_LISTEN_FD" "$connection_fd" "${(@k)REMOTE_CONNECTION_PHASE}"; then
    REMOTE_MODEL_STATUS=error
    REMOTE_MODEL_ERROR="${HTTP_ERROR:-could not check Ollama model residency}"
    return 1
  fi
  REMOTE_MODEL_REQUEST_KIND="$kind"
  REMOTE_MODEL_DEADLINE=$(( EPOCHREALTIME + REMOTE_SERVER_MODEL_CHECK_TIMEOUT ))
  # Preserve the protocol-1 preparation state understood by older clients.
  REMOTE_MODEL_STATUS=warming
  REMOTE_MODEL_ERROR=''
}

_remote_server_model_start_warmup() {
  local connection_fd="${1:-}" payload=""
  agent_build_warmup_payload
  payload="$REPLY"
  if ! http_async_start POST /api/chat "$payload" "$OLLAMA_HOST" "$REMOTE_LISTEN_FD" "$connection_fd" "${(@k)REMOTE_CONNECTION_PHASE}"; then
    REMOTE_MODEL_STATUS="error"
    REMOTE_MODEL_ERROR="${HTTP_ERROR:-could not start Ollama warm-up}"
    zcoder_debug remote_warmup_start_error "model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} error=${(qqq)REMOTE_MODEL_ERROR}"
    return 1
  fi
  REMOTE_MODEL_STATUS="warming"
  REMOTE_MODEL_REQUEST_KIND=warmup
  REMOTE_MODEL_DEADLINE=$(( EPOCHREALTIME + HTTP_READ_TIMEOUT ))
  REMOTE_MODEL_ERROR=""
  zcoder_debug remote_warmup_start "model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} payload_chars=${#payload}"
}

# Check residency only at meaningful boundaries: initial connection and just
# before a turn. Status polling merely collects an existing warm-up so several
# configured servers do not continually fight over constrained model memory.
_remote_server_model_ensure() {
  local -i force="${1:-0}"
  local connection_fd="${2:-}"
  if [[ "$REMOTE_MODEL_STATUS" == warming ]]; then
    _remote_server_model_poll
    return $?
  fi
  if (( ! force )) && [[ "$REMOTE_MODEL_STATUS" == ready ]]; then
    return 0
  fi
  _remote_server_model_start_check check "$connection_fd" || return 2
  return 1
}

remote_server_request_approval() {
  local command_text="$1" approval_kind="${2:-command}" approval_id="${REMOTE_TURN_ID}_${RANDOM}" id_json="" command_json="" kind_json=""
  local pending="$REMOTE_RUNTIME_DIR/pending_approval" response="$REMOTE_RUNTIME_DIR/approvals/${approval_id}.response"
  local decision="n"
  local -F deadline=$(( EPOCHREALTIME + REMOTE_APPROVAL_TIMEOUT ))
  zjson_quote "$approval_id"; id_json="$REPLY"
  zjson_quote "$command_text"; command_json="$REPLY"
  [[ "$approval_kind" == external ]] || approval_kind="command"
  zjson_quote "$approval_kind"; kind_json="$REPLY"
  mapfile[$pending]="$approval_id" || { REPLY="n"; return 1; }
  _remote_server_publish_json "{\"event\":\"approval_required\",\"id\":${id_json},\"kind\":${kind_json},\"command\":${command_json}}" || {
    zf_rm -f "$pending" 2>/dev/null
    REPLY="n"
    return 1
  }
  while [[ ! -f "$response" ]] && (( EPOCHREALTIME < deadline )); do zselect -t 2 2>/dev/null; done
  if [[ -f "$response" ]]; then decision="${mapfile[$response]}"; fi
  zf_rm -f "$pending" "$response" 2>/dev/null
  [[ "$decision" == y || "$decision" == a ]] || decision="n"
  REPLY="$decision"
  [[ "$decision" != n ]]
}

_remote_server_clear_turn_runtime() {
  zf_rm -f "$REMOTE_RUNTIME_DIR"/events/*.json(N) \
    "$REMOTE_RUNTIME_DIR"/approvals/*.response(N) \
    "$REMOTE_RUNTIME_DIR"/{pending_approval,pending_prompt,pending_structured_events,worker.done}(N) 2>/dev/null
}

_remote_server_next_event() {
  local after="$1" event_dir="$REMOTE_RUNTIME_DIR/events" file="" base="" json="" seq_json=""
  local -a files=("$event_dir"/*.json(N))
  [[ "$after" == <0-> ]] || after=0
  for file in "${files[@]}"; do
    base="${file:t:r}"
    [[ "$base" == <0-> ]] || continue
    (( 10#$base > after )) || continue
    json="${mapfile[$file]}"
    seq_json=$(( 10#$base ))
    [[ "$json" == \{*\} ]] || continue
    REPLY="{\"seq\":${seq_json},${json[2,-1]}"
    return 0
  done
  REPLY='{"event":"none"}'
  return 1
}

_remote_server_refresh_sessions() {
  local -i saved_state_enabled=$STATE_ENABLED
  STATE_ENABLED=1
  state_refresh_sessions_list
  STATE_ENABLED=$saved_state_enabled
}

_remote_server_session_summary() {
  local after="$1" id="" session_dir="" title_json="" id_json="" model_json="" current=0
  local -i index agent_count=0 ui_count=0 empty=0
  local -a reply=()
  [[ "$after" == <0-> ]] || after=0
  _remote_server_refresh_sessions
  index=$(( after + 1 ))
  if (( index > ${#SESSION_IDS} )); then
    REPLY='{"event":"none"}'
    return 1
  fi
  id="${SESSION_IDS[index]}"
  session_dir="$ZCODER_SESSIONS_DIR/${id}.session"
  state_snapshot_values "$session_dir" agent_message_count ui_event_count title model || return 2
  [[ "$id" == "$REMOTE_SESSION_ID" ]] && current=1
  _state_nonnegative "${reply[1]:-0}"; agent_count=$REPLY
  _state_nonnegative "${reply[2]:-0}"; ui_count=$REPLY
  (( agent_count == 0 && ui_count == 0 )) && empty=1
  zjson_quote "$id"; id_json="$REPLY"
  zjson_quote "${reply[3]:-Untitled}"; title_json="$REPLY"
  zjson_quote "${reply[4]:-unknown}"; model_json="$REPLY"
  REPLY="{\"event\":\"session\",\"seq\":${index},\"id\":${id_json},\"title\":${title_json},\"model\":${model_json},\"current\":${current},\"empty\":${empty}}"
}

_remote_server_session_event() {
  local id="$1" after="$2"
  _state_valid_id "$id" || return 2
  [[ "$after" == <0-> ]] || return 2
  state_with_snapshot "$ZCODER_SESSIONS_DIR/${id}.session" _remote_server_session_event_snapshot "$after"
}

# state_with_snapshot owns the read lease and dynamically scoped session_dir
# through the final record read, including refs into earlier generations.
_remote_server_session_event_snapshot() {
  local after="$1" ui_dir="" seq=""
  local role_json="" content_json="" thinking_json="" time_json="" reasoning_open="0" metadata_json=""
  local -i index count
  local -a reply=()
  [[ -d "$session_dir" ]] || return 2
  _state_scope_matches "${mapfile[$session_dir/workspace]}" "${mapfile[$session_dir/profile]}" || return 2
  _state_nonnegative "${mapfile[$session_dir/ui_event_count]:-0}"; count=$REPLY
  index=$(( after + 1 ))
  if (( index > count )); then
    REPLY='{"event":"none"}'
    return 1
  fi
  printf -v seq '%06d' "$index"
  state_record_paths "$session_dir" ui_events "$count" || return 2
  ui_dir="${reply[index]:h}"
  seq="${reply[index]:t}"
  [[ -f "$ui_dir/$seq.role" ]] || return 2
  zjson_quote "${mapfile[$ui_dir/$seq.role]:-system}"; role_json="$REPLY"
  zjson_quote "${mapfile[$ui_dir/$seq.content]}"; content_json="$REPLY"
  zjson_quote "${mapfile[$ui_dir/$seq.thinking]}"; thinking_json="$REPLY"
  zjson_quote "${mapfile[$ui_dir/$seq.time]}"; time_json="$REPLY"
  zjson_quote "${mapfile[$ui_dir/$seq.meta]:-}"; metadata_json="$REPLY"
  _state_nonnegative "${mapfile[$ui_dir/$seq.reasoning_open]:-0}"; reasoning_open=$REPLY
  (( reasoning_open > 0 )) && reasoning_open=1
  REPLY="{\"event\":\"message\",\"seq\":${index},\"role\":${role_json},\"content\":${content_json},\"thinking\":${thinking_json},\"time\":${time_json},\"reasoning_open\":${reasoning_open},\"metadata\":${metadata_json}}"
}

_remote_server_select_session() {
  local id="$1" session_dir=""
  local -a reply=()
  _state_valid_id "$id" || return 1
  session_dir="$ZCODER_SESSIONS_DIR/${id}.session"
  [[ -d "$session_dir" ]] || return 1
  state_snapshot_values "$session_dir" workspace profile || return 2
  _state_scope_matches "${reply[1]}" "${reply[2]}" || return 1
  REMOTE_SESSION_ID="$id"
  mapfile[$REMOTE_RUNTIME_DIR/selected_session]="$id"
}

_remote_server_new_session() {
  local -i saved_state_enabled=$STATE_ENABLED
  local -i create_status=0
  STATE_ENABLED=0
  CURRENT_SESSION_ID=""
  agent_reset
  UI_ROLES=()
  UI_CONTENTS=()
  UI_THINKINGS=()
  UI_TIMES=()
  UI_REASONING_OPEN=()
  STATE_ENABLED=1
  state_new_session || create_status=$?
  if (( create_status == 0 )); then
    REMOTE_SESSION_ID="$CURRENT_SESSION_ID"
    mapfile[$REMOTE_RUNTIME_DIR/selected_session]="$REMOTE_SESSION_ID" || create_status=$?
  fi
  STATE_ENABLED=$saved_state_enabled
  return "$create_status"
}

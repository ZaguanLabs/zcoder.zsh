# Authenticated remote-agent client transport and event handling.

remote_normalize_endpoint() {
  local endpoint="$1"
  REMOTE_ERROR=""
  endpoint="${endpoint##[[:space:]]#}"
  endpoint="${endpoint%%[[:space:]]#}"
  if [[ "$endpoint" == https://* ]]; then
    REMOTE_ERROR="HTTPS is not supported by the native Zsh TCP transport"
    return 1
  fi
  endpoint="${endpoint#http://}"
  endpoint="${endpoint%/}"
  if [[ -z "$endpoint" || "$endpoint" == */* || "$endpoint" == *[[:space:]]* ]]; then
    REMOTE_ERROR="expected hostname:port or http://hostname:port"
    return 1
  fi
  if [[ "$endpoint" == \[*\] ]]; then
    endpoint+=":7337"
  elif [[ "$endpoint" == \[*\]:<-> || "$endpoint" == *:<-> ]]; then
    :
  elif [[ "$endpoint" == *:* ]]; then
    REMOTE_ERROR="IPv6 addresses must be enclosed in brackets"
    return 1
  else
    endpoint+=":7337"
  fi
  REPLY="$endpoint"
}

remote_client_auth_header() {
  REPLY="Authorization: Bearer ${REMOTE_TOKEN}"$'\r\n'
}

remote_client_request() {
  local method="$1" request_target="$2" payload="${3:-}" error_body=""
  local -i request_status=0
  REMOTE_REQUEST_CANCELLED=0
  REMOTE_ERROR=''
  HTTP_BODY=''
  remote_client_auth_header
  if (( ${UI_ACTIVE:-0} && $+functions[ui_wait_for_remote_request] )); then
    _remote_client_request_interactive "$method" "$request_target" "$payload" "$REPLY"
    request_status=$?
  else
    http_request "$method" "$request_target" "$payload" "$REMOTE_ENDPOINT" "$REPLY"
    request_status=$?
  fi
  if (( request_status != 0 )); then
    error_body="$HTTP_BODY"
    if [[ -n "$error_body" ]] && json_parse_flat_object "$error_body" && [[ -n "${JSON_OBJECT[error]:-}" ]]; then
      REMOTE_ERROR="${JSON_OBJECT[error]}"
    else
      REMOTE_ERROR="${HTTP_ERROR//Ollama/remote server}"
      [[ "$method" == POST ]] && REMOTE_ERROR+='; the server may already have acted on this request'
    fi
    return "$request_status"
  fi
  return 0
}

# Request-local worker ownership keeps remote traffic separate from any local
# warm-up state. Only the child owns TCP; the parent owns UI and dispatch.
_remote_client_request_interactive() {
  local method="$1" target="$2" payload="$3" HTTP_ASYNC_EXTRA_HEADERS="$4"
  local HTTP_ASYNC_PID='' HTTP_ASYNC_BASE='' HTTP_ASYNC_STREAM_FD='' HTTP_ACTIVE_FD=''
  local -i HTTP_STREAM_REQUEST=0 HTTP_READ_TIMEOUT=$REMOTE_REQUEST_TIMEOUT wait_status=0
  [[ "$HTTP_READ_TIMEOUT" == <1-3600> ]] || HTTP_READ_TIMEOUT=30
  local -F remote_request_deadline=$(( EPOCHREALTIME + HTTP_READ_TIMEOUT ))
  {
    http_async_start "$method" "$target" "$payload" "$REMOTE_ENDPOINT" || return 1
    ui_wait_for_remote_request
    wait_status=$?
    if (( wait_status != 0 )); then
      http_async_cancel 'remote request wait stopped'
      if (( wait_status == 130 )); then
        REMOTE_REQUEST_CANCELLED=1
        HTTP_ERROR='Remote request cancelled by user'
      elif (( wait_status == 124 )); then
        HTTP_ERROR="Remote request timed out after ${HTTP_READ_TIMEOUT}s"
      else HTTP_ERROR="Remote request input wait failed with status ${wait_status}"
      fi
      return "$wait_status"
    fi
    http_async_collect
  } always {
    [[ -n "$HTTP_ASYNC_PID" || -n "$HTTP_ASYNC_BASE" ]] && http_async_cancel 'remote request cleanup'
  }
}

remote_client_request_expired() { (( EPOCHREALTIME >= remote_request_deadline )); }

remote_client_handshake() {
  local protocol="" server_name="" workspace="" model="" profile="" command_policy="" sessions="" harnesses="" goals=""
  remote_load_token "$REMOTE_TOKEN_FILE" || return 1
  remote_client_request GET /v1/hello || return $?
  json_parse_flat_object "$HTTP_BODY" || { REMOTE_ERROR="invalid server handshake: ${ZJSON_ERROR:-parse error}"; return 1; }
  protocol="${JSON_OBJECT[protocol]:-}"
  server_name="${JSON_OBJECT[server_name]:-Remote zcoder}"
  workspace="${JSON_OBJECT[workspace]:-remote-workspace}"
  model="${JSON_OBJECT[model]:-unknown}"
  profile="${JSON_OBJECT[profile]:-coding}"
  command_policy="${JSON_OBJECT[command_policy]:-ask}"
  sessions="${JSON_OBJECT[sessions]:-false}"
  goals="${JSON_OBJECT[goals]:-false}"
  REMOTE_INPUT_SUPPORTED="${JSON_OBJECT[input_queue]:-false}"
  [[ "$protocol" == 1 ]] || { REMOTE_ERROR="unsupported remote protocol: ${protocol:-missing}"; return 1; }
  REMOTE_SERVER_NAME="$server_name"
  ZCODER_WORKSPACE="$workspace"
  ZCODER_MODEL="$model"
  ZCODER_PROFILE="$profile"
  ZCODER_COMMAND_POLICY="$command_policy"
  # Protocol-1 servers predating connection-aware warm-up omit this field.
  # Keep those servers usable and let their first real turn load the model.
  REMOTE_MODEL_STATUS="${JSON_OBJECT[model_status]:-unmanaged}"
  REMOTE_MODEL_ERROR="${JSON_OBJECT[model_error]:-}"
  REMOTE_GIT_SUPPORTED=0
  [[ "${JSON_OBJECT_TYPES[git_status]:-}" == string ]] && REMOTE_GIT_SUPPORTED=1
  REMOTE_GIT_STATUS="${JSON_OBJECT[git_status]:-Git: unavailable}"
  if (( ${+JSON_OBJECT[harnesses]} )) && [[ "${JSON_OBJECT_TYPES[harnesses]:-}" == string ]]; then
    harnesses="${JSON_OBJECT[harnesses]}"
    REMOTE_HARNESSES="$harnesses"
    REMOTE_HARNESS_DISCOVERY_SUPPORTED=1
    if (( ! $+functions[delegate_set_available_csv] && $+functions[zcoder_require] )); then
      zcoder_require harnesses
    fi
    (( $+functions[delegate_set_available_csv] )) && delegate_set_available_csv "$harnesses"
  else
    REMOTE_HARNESSES=""
    REMOTE_HARNESS_DISCOVERY_SUPPORTED=0
  fi
  if [[ "$sessions" == true ]]; then
    REMOTE_SESSIONS_SUPPORTED=1
    if (( ${ACP_MODE:-0} )); then
      remote_client_refresh_sessions || return $?
    else
      remote_client_start_session || return $?
    fi
  else
    REMOTE_SESSIONS_SUPPORTED=0
    [[ -z "${RESUME_SESSION_ID:-}" ]] || { REMOTE_ERROR='this server does not support saved sessions'; return 1; }
  fi
  [[ "$goals" == true ]] && REMOTE_GOALS_SUPPORTED=1 || REMOTE_GOALS_SUPPORTED=0
}

remote_client_start_session() {
  if [[ -n "${RESUME_SESSION_ID:-}" ]]; then
    remote_client_select_session "$RESUME_SESSION_ID"
  else
    remote_client_new_session
  fi
}

remote_client_refresh_sessions() {
  local event="" id="" title="" model="" current="0" empty="0"
  local -i cursor=0 next_cursor=0 adopt_current=${1:-$(( ! REMOTE_SESSION_SYNC_REQUIRED ))}
  local current_id="$CURRENT_SESSION_ID"
  local listed_current=''
  local -i current_empty=0
  local -a ids=() titles=() models=()
  while true; do
    remote_client_request GET "/v1/sessions?after=${cursor}" || return $?
    json_parse_flat_object "$HTTP_BODY" || {
      REMOTE_ERROR="invalid remote session list: ${ZJSON_ERROR:-parse error}"
      return 1
    }
    event="${JSON_OBJECT[event]:-}"
    [[ "$event" == none ]] && break
    [[ "$event" == session && "${JSON_OBJECT[seq]:-}" == <1-> ]] || {
      REMOTE_ERROR="invalid remote session list entry"
      return 1
    }
    next_cursor="${JSON_OBJECT[seq]}"
    (( next_cursor > cursor )) || { REMOTE_ERROR="remote session list cursor did not advance"; return 1; }
    cursor=$next_cursor
    id="${JSON_OBJECT[id]:-}"
    _state_valid_id "$id" || { REMOTE_ERROR="invalid remote session identifier"; return 1; }
    title="${JSON_OBJECT[title]:-Untitled}"
    model="${JSON_OBJECT[model]:-unknown}"
    current="${JSON_OBJECT[current]:-0}"
    empty="${JSON_OBJECT[empty]:-0}"
    ids+=("$id")
    titles+=("$title")
    models+=("$model")
    if [[ "$current" == 1 ]]; then
      listed_current="$id"
      current_id="$id"
      [[ "$empty" == 1 ]] && current_empty=1 || current_empty=0
    fi
  done
  SESSION_IDS=("${ids[@]}")
  SESSION_TITLES=("${titles[@]}")
  SESSION_MODELS=("${models[@]}")
  REMOTE_LIST_CURRENT_ID="$listed_current"
  REMOTE_LIST_CURRENT_EMPTY=$current_empty
  if (( ${UI_ACTIVE:-0} )) && [[ -n "$CURRENT_SESSION_ID" && "$listed_current" != "$CURRENT_SESSION_ID" ]]; then
    REMOTE_SESSION_SYNC_REQUIRED=1
    adopt_current=0
  fi
  (( adopt_current )) || return 0
  if (( ${#SESSION_IDS} == 0 )); then
    CURRENT_SESSION_ID=""
    SESSION_TITLE="New Job"
    REMOTE_SESSION_EMPTY=1
  elif (( ! ${SESSION_IDS[(Ie)$current_id]} )); then
    CURRENT_SESSION_ID="${SESSION_IDS[1]}"
    SESSION_TITLE="${SESSION_TITLES[1]}"
    REMOTE_SESSION_EMPTY=0
  else
    CURRENT_SESSION_ID="$current_id"
    local -i current_index=${SESSION_IDS[(Ie)$current_id]}
    SESSION_TITLE="${SESSION_TITLES[current_index]}"
    REMOTE_SESSION_EMPTY=$current_empty
  fi
}

remote_client_load_session() {
  local id="$1" event="" role="" content="" thinking="" time="" reasoning_open="0" metadata=""
  local -i cursor=0 next_cursor=0 index=${SESSION_IDS[(Ie)$id]}
  local -a roles=() contents=() thinkings=() times=() reasoning=() records=()
  _state_valid_id "$id" || { REMOTE_ERROR="invalid remote session identifier"; return 1; }
  # Stage pages separately: activity callbacks continue rendering and folding
  # the current transcript until every page of the replacement has arrived.
  while true; do
    remote_client_request GET "/v1/session?id=${id}&after=${cursor}" || return $?
    json_parse_flat_object "$HTTP_BODY" || {
      REMOTE_ERROR="invalid remote session transcript: ${ZJSON_ERROR:-parse error}"
      return 1
    }
    event="${JSON_OBJECT[event]:-}"
    [[ "$event" == none ]] && break
    [[ "$event" == message && "${JSON_OBJECT[seq]:-}" == <1-> ]] || {
      REMOTE_ERROR="invalid remote session transcript entry"
      return 1
    }
    next_cursor="${JSON_OBJECT[seq]}"
    (( next_cursor > cursor )) || { REMOTE_ERROR="remote transcript cursor did not advance"; return 1; }
    cursor=$next_cursor
    role="${JSON_OBJECT[role]:-system}"
    content="${JSON_OBJECT[content]:-}"
    thinking="${JSON_OBJECT[thinking]:-}"
    time="${JSON_OBJECT[time]:-}"
    reasoning_open="${JSON_OBJECT[reasoning_open]:-0}"
    metadata="${JSON_OBJECT[metadata]:-}"
    roles+=("$role"); contents+=("$content"); thinkings+=("$thinking"); times+=("$time")
    [[ "$reasoning_open" == 1 ]] && reasoning+=(1) || reasoning+=(0)
    records+=("$metadata")
  done
  transcript_reset
  UI_ROLES=("${roles[@]}"); UI_CONTENTS=("${contents[@]}"); UI_THINKINGS=("${thinkings[@]}")
  UI_TIMES=("${times[@]}"); UI_REASONING_OPEN=("${reasoning[@]}")
  for (( cursor=1; cursor<=${#records}; cursor++ )); do transcript_restore_metadata "$cursor" "${records[cursor]}"; done
  CURRENT_SESSION_ID="$id"
  (( index > 0 )) && SESSION_TITLE="${SESSION_TITLES[index]}"
  (( UI_TRANSCRIPT_GENERATION++ ))
  UI_SCROLL=0
  UI_AUTO_SCROLL=1
}

remote_client_select_session() {
  local id="$1" id_json=""
  (( REMOTE_SESSIONS_SUPPORTED )) || { REMOTE_ERROR="remote session browsing is not supported by this server"; return 1; }
  remote_client_idle_cancel
  REMOTE_SESSION_SYNC_REQUIRED=1
  zjson_quote "$id"; id_json="$REPLY"
  remote_client_request POST /v1/session/select "{\"id\":${id_json}}" || return $?
  remote_client_refresh_sessions 0 || return $?
  [[ "$REMOTE_LIST_CURRENT_ID" == "$id" ]] || { REMOTE_ERROR='server selected a different session; refresh before sending a prompt'; return 1; }
  remote_client_load_session "$id" || return $?
  REMOTE_SESSION_EMPTY=$REMOTE_LIST_CURRENT_EMPTY
  REMOTE_SESSION_SYNC_REQUIRED=0
}

remote_client_new_session() {
  local id=""
  (( REMOTE_SESSIONS_SUPPORTED )) || { REMOTE_ERROR="remote session creation is not supported by this server"; return 1; }
  remote_client_idle_cancel
  REMOTE_SESSION_SYNC_REQUIRED=1
  remote_client_request POST /v1/session/new '{}' || return $?
  json_parse_flat_object "$HTTP_BODY" || { REMOTE_ERROR="invalid remote new-session response"; return 1; }
  id="${JSON_OBJECT[id]:-}"
  _state_valid_id "$id" || { REMOTE_ERROR="invalid remote new-session identifier"; return 1; }
  remote_client_refresh_sessions 0 || return $?
  [[ "$REMOTE_LIST_CURRENT_ID" == "$id" ]] || { REMOTE_ERROR='server selected a different session; refresh before sending a prompt'; return 1; }
  remote_client_load_session "$id" || return $?
  REMOTE_SESSION_EMPTY=$REMOTE_LIST_CURRENT_EMPTY
  REMOTE_SESSION_SYNC_REQUIRED=0
}

remote_client_reconcile_session() {
  (( REMOTE_SESSION_SYNC_REQUIRED )) || return 0
  remote_client_refresh_sessions 0 || return $?
  _state_valid_id "$REMOTE_LIST_CURRENT_ID" || { REMOTE_ERROR='server did not identify its current session'; return 1; }
  remote_client_load_session "$REMOTE_LIST_CURRENT_ID" || return $?
  REMOTE_SESSION_EMPTY=$REMOTE_LIST_CURRENT_EMPTY
  REMOTE_SESSION_SYNC_REQUIRED=0
}

_remote_client_parse_model_status() {
  if ! json_parse_flat_object "$HTTP_BODY"; then
    REMOTE_ERROR="invalid remote model status: ${ZJSON_ERROR:-parse error}"
    return 1
  fi
  REMOTE_MODEL_STATUS="${JSON_OBJECT[model_status]:-unknown}"
  REMOTE_MODEL_ERROR="${JSON_OBJECT[model_error]:-}"
  [[ "${JSON_OBJECT_TYPES[git_status]:-}" == string ]] && REMOTE_GIT_STATUS="${JSON_OBJECT[git_status]}"
  [[ "$REMOTE_MODEL_STATUS" == ready || "$REMOTE_MODEL_STATUS" == warming || "$REMOTE_MODEL_STATUS" == error ]] || {
    REMOTE_ERROR="invalid remote model status: ${REMOTE_MODEL_STATUS}"
    return 1
  }
}

# The idle loop owns a separate HTTP job and checks it without entering an
# activity wait. A foreground operation cancels it before changing context.
remote_client_idle_cancel() {
  local HTTP_ASYNC_PID="$REMOTE_IDLE_PID" HTTP_ASYNC_BASE="$REMOTE_IDLE_BASE" HTTP_ASYNC_STREAM_FD=''
  local HTTP_BODY='' HTTP_ERROR=''
  [[ -n "$HTTP_ASYNC_PID" || -n "$HTTP_ASYNC_BASE" ]] && http_async_cancel 'remote model poll superseded'
  REMOTE_IDLE_PID=''; REMOTE_IDLE_BASE=''; REMOTE_IDLE_ENDPOINT=''
  return 0
}

remote_client_idle_poll() {
  if [[ ( "$REMOTE_MODEL_STATUS" != warming && "$REMOTE_GIT_SUPPORTED" == 0 ) || ( -n "$REMOTE_IDLE_PID" && "$REMOTE_IDLE_ENDPOINT" != "$REMOTE_ENDPOINT" ) ]]; then
    remote_client_idle_cancel
    return 0
  fi
  local HTTP_ASYNC_PID="$REMOTE_IDLE_PID" HTTP_ASYNC_BASE="$REMOTE_IDLE_BASE" HTTP_ASYNC_STREAM_FD='' HTTP_ACTIVE_FD=''
  local HTTP_BODY='' HTTP_ERROR='' HTTP_ASYNC_EXTRA_HEADERS=''
  local previous_model_status="$REMOTE_MODEL_STATUS" previous_model_error="$REMOTE_MODEL_ERROR"
  local -i HTTP_STREAM_REQUEST=0 HTTP_READ_TIMEOUT=$REMOTE_REQUEST_TIMEOUT request_status=0
  local -i warming_poll=0
  [[ "$REMOTE_MODEL_STATUS" == warming ]] && warming_poll=1
  [[ "$HTTP_READ_TIMEOUT" == <1-3600> ]] || HTTP_READ_TIMEOUT=30
  {
    if [[ -z "$HTTP_ASYNC_PID" ]]; then
      (( EPOCHREALTIME >= REMOTE_CLIENT_NEXT_MODEL_POLL )) || return 0
      remote_client_auth_header; HTTP_ASYNC_EXTRA_HEADERS="$REPLY"
      REMOTE_IDLE_ENDPOINT="$REMOTE_ENDPOINT"
      REMOTE_IDLE_DEADLINE=$(( EPOCHREALTIME + HTTP_READ_TIMEOUT ))
      if http_async_start GET /v1/model '' "$REMOTE_ENDPOINT"; then return 0; fi
      REMOTE_MODEL_ERROR="${HTTP_ERROR//Ollama/remote server}"
    elif ! http_async_ready; then
      (( EPOCHREALTIME >= REMOTE_IDLE_DEADLINE )) || return 0
      http_async_cancel 'remote model poll timed out'
      REMOTE_MODEL_ERROR='Remote model status request timed out'
    else
      http_async_collect
      request_status=$?
      REMOTE_CLIENT_NEXT_MODEL_POLL=$(( EPOCHREALTIME + REMOTE_CLIENT_MODEL_POLL_INTERVAL ))
      if (( request_status == 0 )) && _remote_client_parse_model_status; then
        # Idle branch refreshes must not replace an unrelated foreground status.
        if (( ! warming_poll )); then
          REMOTE_CLIENT_NEXT_MODEL_POLL=$(( EPOCHREALTIME + 2.0 ))
          return 0
        fi
        case "$REMOTE_MODEL_STATUS" in
          ready) agent_set_status Ready; return 0 ;;
          warming) agent_set_status 'Warming Up'; return 0 ;;
          error) agent_set_status 'Warm-up Failed'; return 1 ;;
        esac
      fi
      REMOTE_MODEL_ERROR="${HTTP_ERROR:-$REMOTE_ERROR}"
    fi
    if (( ! warming_poll )); then
      REMOTE_MODEL_STATUS="$previous_model_status"
      REMOTE_MODEL_ERROR="$previous_model_error"
      REMOTE_GIT_STATUS='Git: unavailable'
      REMOTE_CLIENT_NEXT_MODEL_POLL=$(( EPOCHREALTIME + 2.0 ))
      return 0
    fi
    REMOTE_MODEL_STATUS=error
    agent_set_status 'Warm-up Failed'
    return 1
  } always {
    REMOTE_IDLE_PID="$HTTP_ASYNC_PID"; REMOTE_IDLE_BASE="$HTTP_ASYNC_BASE"
  }
}

remote_client_model_poll() {
  local -i force="${1:-0}"
  if (( ! force && ${UI_ACTIVE:-0} )); then remote_client_idle_poll; return $?; fi
  local -F now=$EPOCHREALTIME
  [[ "$REMOTE_MODEL_STATUS" == warming ]] || return 0
  if (( ! force && now < REMOTE_CLIENT_NEXT_MODEL_POLL )); then
    return 0
  fi
  REMOTE_CLIENT_NEXT_MODEL_POLL=$(( now + REMOTE_CLIENT_MODEL_POLL_INTERVAL ))
  if ! remote_client_request GET /v1/model; then
    (( REMOTE_REQUEST_CANCELLED )) && return 130
    REMOTE_MODEL_STATUS="error"
    REMOTE_MODEL_ERROR="$REMOTE_ERROR"
    agent_set_status "Warm-up Failed"
    return 1
  fi
  _remote_client_parse_model_status || {
    REMOTE_MODEL_STATUS="error"
    REMOTE_MODEL_ERROR="$REMOTE_ERROR"
    agent_set_status "Warm-up Failed"
    return 1
  }
  case "$REMOTE_MODEL_STATUS" in
    ready) agent_set_status "Ready" ;;
    warming) agent_set_status "Warming Up" ;;
    error) agent_set_status "Warm-up Failed"; return 1 ;;
  esac
}

remote_client_model_ensure() {
  local -i poll_status=0 announced=0
  remote_client_idle_cancel
  if [[ "$REMOTE_MODEL_STATUS" == unmanaged ]]; then
    agent_set_status "Ready"
    return 0
  fi
  agent_set_status "Checking Model"
  if ! remote_client_request POST /v1/model/ensure '{}'; then
    (( REMOTE_REQUEST_CANCELLED )) && { remote_client_cancel_preparation; return 130; }
    REMOTE_MODEL_STATUS="error"
    REMOTE_MODEL_ERROR="$REMOTE_ERROR"
    agent_set_status "Warm-up Failed"
    return 1
  fi
  _remote_client_parse_model_status || {
    REMOTE_MODEL_STATUS="error"
    REMOTE_MODEL_ERROR="$REMOTE_ERROR"
    agent_set_status "Warm-up Failed"
    return 1
  }
  while [[ "$REMOTE_MODEL_STATUS" == warming ]]; do
    agent_set_status "Warming Up"
    if (( ! ${UI_ACTIVE:-0} && ! announced )); then
      agent_emit system "Warming the remote model before submitting the prompt."
      announced=1
    fi
    if (( ${UI_ACTIVE:-0} && $+functions[ui_poll_remote_turn] )); then
      ui_poll_remote_turn
      poll_status=$?
      if (( poll_status == 130 )); then
        remote_client_cancel_preparation
        return 130
      fi
    else
      zselect -t 1 2>/dev/null
    fi
    remote_client_model_poll 1
    poll_status=$?
    if (( poll_status != 0 )); then
      (( poll_status == 130 )) && { remote_client_cancel_preparation; return 130; }
      return 1
    fi
  done
  if [[ "$REMOTE_MODEL_STATUS" == ready ]]; then
    agent_set_status "Ready"
    return 0
  fi
  REMOTE_ERROR="${REMOTE_MODEL_ERROR:-remote model warm-up failed}"
  agent_set_status "Warm-up Failed"
  return 1
}

remote_client_cancel_preparation() {
  agent_emit system "⏹ Prompt cancelled before it was sent; remote model preparation may continue."
  agent_set_status "Stopped"
}

_remote_client_emit_event() {
  local event="$1" role="$2" content="$3" thinking="$4" event_status="$5"
  case "$event" in
    message)
      [[ "$role" == assistant ]] && AGENT_LAST_RESPONSE="$content"
      agent_emit "$role" "$content" "$thinking"
      ;;
    status)
      agent_set_status "$event_status"
      ;;
  esac
}

remote_client_cancel_turn() {
  local continue_queued="${1:-false}"
  local -i REMOTE_REQUEST_TIMEOUT=2 REMOTE_REQUEST_CANCELLED=0 acknowledged=0
  REMOTE_CANCEL_CONTINUED=0
  local cancel_payload='{}' session_json='' turn_json=''
  # A turn receipt lets the server reject delayed cancellation after another
  # client starts work. Before a receipt, retain the legacy cancellation path.
  if [[ -n "$REMOTE_INPUT_TURN_ID" ]]; then
    zjson_quote "$CURRENT_SESSION_ID"; session_json=$REPLY
    zjson_quote "$REMOTE_INPUT_TURN_ID"; turn_json=$REPLY
    cancel_payload="{\"session_id\":$session_json,\"turn_id\":$turn_json}"
    [[ "$continue_queued" == true && "$REMOTE_INPUT_SUPPORTED" == true ]] && cancel_payload="${cancel_payload%\}},\"continue_queued\":true}"
  fi
  if remote_client_request POST /v1/cancel "$cancel_payload" >/dev/null 2>&1 &&
     json_parse_flat_object "$HTTP_BODY" && [[ "${JSON_OBJECT[ok]:-}" == true ]]; then
    acknowledged=1
    [[ "$continue_queued" == true && "${JSON_OBJECT[continued]:-false}" == true ]] && REMOTE_CANCEL_CONTINUED=1
  fi
  transcript_interrupt_tool || true
  if (( REMOTE_CANCEL_CONTINUED )); then
    agent_emit system 'Current operation stopped. Continuing with queued input.'
    agent_set_status Working
  elif (( acknowledged )); then
    agent_emit system "⏹ Server acknowledged the stop request. Completed side effects were not rolled back."
    agent_set_status "Stopped"
  else
    agent_emit system "⏹ Stopped waiting locally; the server did not confirm cancellation. Remote work may still be running."
    agent_set_status "Stop unconfirmed"
  fi
}

remote_client_user_turn() {
  local REMOTE_INPUT_TURN_ID=''
  local -i interactive=0 REMOTE_CANCEL_CONTINUED=0
  REMOTE_REQUEST_CANCELLED=0
  remote_client_idle_cancel
  (( ${UI_ACTIVE:-0} && $+functions[ui_activity_begin] )) && interactive=1
  (( interactive )) && ui_activity_begin
  {
    _remote_client_user_turn "$@"
  } always {
    (( interactive )) && ui_activity_end
  }
}

_remote_client_user_turn() {
  local user_content="$1" prompt_json="" turn_payload="" event="" role="" content="" thinking="" event_status=""
  local approval_id="" approval_kind="" command_text="" answer="n" decision="n" approval_json="" exit_code="0"
  local tool_phase="" tool_name="" tool_args="{}" tool_result="" tool_succeeded="0" tool_id=""
  local -i poll_status=0 structured_tool_seen=0
  if ! remote_client_reconcile_session; then
    (( REMOTE_REQUEST_CANCELLED )) && return 130
    agent_emit error "Could not reconcile the remote session: $REMOTE_ERROR"
    return 1
  fi
  AGENT_LAST_RESPONSE=""
  if (( ${UI_ACTIVE:-0} )); then
    ui_append_message user "$user_content"
    ui_refresh_all
  fi
  zjson_quote "$user_content"; prompt_json="$REPLY"
  turn_payload="{\"prompt\":${prompt_json}}"
  (( ${ACP_WORKER_ACTIVE:-0} || ${UI_ACTIVE:-0} )) && turn_payload="{\"prompt\":${prompt_json},\"structured_events\":true}"
  remote_client_model_ensure
  poll_status=$?
  if (( poll_status != 0 )); then
    (( poll_status == 130 )) && return 130
    agent_emit error "Remote model preparation failed: ${REMOTE_MODEL_ERROR:-$REMOTE_ERROR}"
    return 1
  fi
  agent_set_status "Connecting"
  while ! remote_client_request POST /v1/turn "$turn_payload"; do
    if (( REMOTE_REQUEST_CANCELLED )); then remote_client_cancel_turn; return 130; fi
    if [[ "$REMOTE_ERROR" == "model is warming" ]]; then
      REMOTE_MODEL_STATUS="warming"
      remote_client_model_ensure || return $?
      agent_set_status "Connecting"
      continue
    fi
    agent_emit error "Remote turn failed: $REMOTE_ERROR"
    agent_set_status "Error"
    return 1
  done
  REMOTE_CLIENT_EVENT_CURSOR=0
  if [[ "$REMOTE_INPUT_SUPPORTED" == true ]]; then
    json_parse_flat_object "$HTTP_BODY" || { REMOTE_ERROR='invalid turn receipt'; return 1; }
    REMOTE_INPUT_TURN_ID="${JSON_OBJECT[turn_id]:-}"
  fi
  while true; do
    # Drain input even when events arrive continuously. The idle/none branch
    # retains its short blocking poll; active traffic adds no input delay.
    if (( ${UI_ACTIVE:-0} && $+functions[ui_poll_remote_turn] )); then
      ui_poll_remote_turn 0
      poll_status=$?
      if (( poll_status == 130 )); then
        remote_client_cancel_turn true
        (( REMOTE_CANCEL_CONTINUED )) || return 130
        REMOTE_REQUEST_CANCELLED=0
        continue
      fi
    fi
    if ! remote_client_request GET "/v1/events?after=${REMOTE_CLIENT_EVENT_CURSOR}"; then
      if (( REMOTE_REQUEST_CANCELLED )); then
        remote_client_cancel_turn true
        (( REMOTE_CANCEL_CONTINUED )) || return 130
        REMOTE_REQUEST_CANCELLED=0
        continue
      fi
      transcript_interrupt_tool || true
      agent_emit error "Remote event request failed: $REMOTE_ERROR"
      agent_set_status "Error"
      return 1
    fi
    if ! json_parse_flat_object "$HTTP_BODY"; then
      transcript_interrupt_tool || true
      agent_emit error "Invalid remote event: ${ZJSON_ERROR:-parse error}"
      agent_set_status "Error"
      return 1
    fi
    event="${JSON_OBJECT[event]:-}"
    [[ "${JSON_OBJECT_TYPES[git_status]:-}" == string ]] && REMOTE_GIT_STATUS="${JSON_OBJECT[git_status]}"
    if [[ "${JSON_OBJECT[seq]:-}" == <0-> ]]; then
      REMOTE_CLIENT_EVENT_CURSOR="${JSON_OBJECT[seq]}"
    fi
    role="${JSON_OBJECT[role]:-}"
    content="${JSON_OBJECT[content]:-}"
    thinking="${JSON_OBJECT[thinking]:-}"
    event_status="${JSON_OBJECT[status]:-}"
    approval_id="${JSON_OBJECT[id]:-}"
    approval_kind="${JSON_OBJECT[kind]:-command}"
    command_text="${JSON_OBJECT[command]:-}"
    exit_code="${JSON_OBJECT[exit_code]:-0}"
    tool_phase="${JSON_OBJECT[phase]:-}"
    tool_name="${JSON_OBJECT[name]:-}"
    tool_args="${JSON_OBJECT[args]:-}"
    [[ -n "$tool_args" ]] || tool_args="{}"
    tool_result="${JSON_OBJECT[result]:-}"
    tool_succeeded="${JSON_OBJECT[succeeded]:-0}"
    tool_id="${JSON_OBJECT[tool_call_id]:-}"
    case "$event" in
      none)
        if (( ${UI_ACTIVE:-0} && $+functions[ui_poll_remote_turn] )); then
          ui_poll_remote_turn
          poll_status=$?
          if (( poll_status == 130 )); then
            remote_client_cancel_turn true
            (( REMOTE_CANCEL_CONTINUED )) || return 130
            REMOTE_REQUEST_CANCELLED=0
            continue
          fi
        else
          zselect -t 1 2>/dev/null
        fi
        ;;
      message|status)
        # Older structured-event servers also send legacy tool text. Once
        # lifecycle events are present, those summaries would duplicate cards.
        if [[ "$event" == message && "$role" == tool ]] && (( ${UI_ACTIVE:-0} && structured_tool_seen )); then
          :
        else
          _remote_client_emit_event "$event" "$role" "$content" "$thinking" "$event_status"
        fi
        ;;
      tool)
        if (( ${ACP_WORKER_ACTIVE:-0} && $+functions[acp_worker_tool_event] )); then
          acp_worker_tool_event "$tool_phase" "$tool_name" "$tool_args" "$tool_result" "$tool_succeeded"
        elif (( ${UI_ACTIVE:-0} )); then
          transcript_tool_event "$tool_phase" "$tool_name" "$tool_args" "$tool_result" "$tool_succeeded" "$tool_id" "${JSON_OBJECT[diff]:-}" && structured_tool_seen=1
          ui_draw_chat
        fi
        ;;
      approval_required)
        answer="n"
        if (( ${ACP_WORKER_ACTIVE:-0} && $+functions[acp_worker_request_permission] )); then
          acp_worker_request_permission "$command_text" "$approval_kind"
          answer="$REPLY"
        elif [[ "$approval_kind" == external ]] && (( $+functions[ui_confirm_external_action] )); then
          ui_confirm_external_action "$command_text"
          answer="$REPLY"
        elif (( $+functions[ui_confirm_command] )); then
          ui_confirm_command "$command_text"
          answer="$REPLY"
        fi
        case "${(L)answer}" in
          y|yes|once) decision="y" ;;
          a|always|session) [[ "$approval_kind" == external ]] && decision="n" || decision="a" ;;
          *) decision="n" ;;
        esac
        zjson_quote "$approval_id"; approval_id="$REPLY"
        zjson_quote "$decision"; decision="$REPLY"
        approval_json="{\"id\":${approval_id},\"decision\":${decision}}"
        if ! remote_client_request POST /v1/approval "$approval_json"; then
          if (( REMOTE_REQUEST_CANCELLED )); then
            remote_client_cancel_turn true
            (( REMOTE_CANCEL_CONTINUED )) || return 130
            REMOTE_REQUEST_CANCELLED=0
            continue
          fi
          agent_emit error "Could not send approval response: $REMOTE_ERROR"
          remote_client_cancel_turn
          return 1
        fi
        ;;
      complete)
        if transcript_interrupt_tool && (( ${UI_ACTIVE:-0} )); then ui_draw_chat; fi
        [[ "$exit_code" == <0-255> ]] || exit_code=1
        if (( REMOTE_SESSIONS_SUPPORTED )) && ! remote_client_refresh_sessions; then
          if (( REMOTE_REQUEST_CANCELLED )); then
            agent_emit system "Remote turn completed; session refresh stopped."
            agent_set_status "Ready"
            return 130
          fi
          agent_emit error "Could not refresh remote sessions: $REMOTE_ERROR"
        fi
        (( exit_code == 0 )) && agent_set_status "Ready" || agent_set_status "Error"
        return "$exit_code"
        ;;
      *)
        transcript_interrupt_tool || true
        agent_emit error "Unknown remote event: ${event:-missing event type}"
        return 1
        ;;
    esac
  done
}

remote_client_input_request() {
  zjson_with_context _remote_client_input_request "$@"
}

_remote_client_input_request() {
  setopt localoptions extendedglob nonomatch
  # This can run inside an event-poll UI wait. Preserve its transport/parser
  # scratch state, and keep its asynchronous worker ownership separate.
  local action="$1" turn="$2" id="$3" mode="$4" text="$5" payload='' endpoint="/v1/input/$1"
  local HTTP_BODY='' HTTP_ERROR=''
  local -A JSON_OBJECT=() JSON_OBJECT_TYPES=()
  local -i REMOTE_REQUEST_CANCELLED=0
  [[ "$REMOTE_INPUT_SUPPORTED" == true ]] || { REMOTE_ERROR='This server does not support queued input.'; return 1; }
  zjson_quote "$CURRENT_SESSION_ID"; payload='{"session_id":'"$REPLY"
  zjson_quote "$turn"; payload+=',"turn_id":'"$REPLY"
  zjson_quote "$id"; payload+=',"message_id":'"$REPLY"
  zjson_quote "$mode"; payload+=',"mode":'"$REPLY"
  zjson_quote "$text"; payload+=',"text":'"$REPLY"'}'
  [[ "$action" == submit ]] && endpoint=/v1/input
  remote_client_request POST "$endpoint" "$payload" || return $?
  json_parse_flat_object "$HTTP_BODY" || { REMOTE_ERROR='invalid input queue response'; return 1; }
  if [[ "$action" == list ]]; then
    [[ "${JSON_OBJECT_TYPES[turn_id]:-}" == string && "${JSON_OBJECT_TYPES[pending]:-}" == string ]] || {
      REMOTE_ERROR='invalid input queue listing'; return 1
    }
  else
    [[ "${JSON_OBJECT[message_id]:-}" == "$id" &&
       ( "${JSON_OBJECT[state]:-}" == accepted || "${JSON_OBJECT[state]:-}" == consumed || "${JSON_OBJECT[state]:-}" == discarded ) ]] || {
      REMOTE_ERROR='input queue receipt does not match the submitted message'; return 1
    }
  fi
  REPLY="$HTTP_BODY"
}

remote_client_submit_input() {
  remote_client_input_request submit "$REMOTE_INPUT_TURN_ID" "$1" "$2" "$3"
}

# Authenticated remote-agent client and native Zsh HTTP server.

typeset -g REMOTE_MODE="${REMOTE_MODE:-local}"
typeset -g REMOTE_SERVER_NAME="${REMOTE_SERVER_NAME:-}"
typeset -g REMOTE_SERVER_PORT="${REMOTE_SERVER_PORT:-7337}"
typeset -g REMOTE_ENDPOINT="${REMOTE_ENDPOINT:-}"
typeset -g REMOTE_TOKEN_FILE="${REMOTE_TOKEN_FILE:-}"
typeset -g REMOTE_TOKEN=""
typeset -g REMOTE_RUNTIME_DIR=""
typeset -g REMOTE_SESSION_ID=""
typeset -g REMOTE_TURN_ID=""
typeset -g REMOTE_LISTEN_FD=""
typeset -g REMOTE_CLIENT_EVENT_CURSOR="0"
typeset -g REMOTE_ERROR=""
typeset -g REMOTE_MODEL_STATUS="unknown"
typeset -g REMOTE_MODEL_ERROR=""
typeset -gi REMOTE_SERVER_WORKER=0
typeset -gi REMOTE_MAX_REQUEST_BYTES="${ZCODER_REMOTE_MAX_REQUEST_BYTES:-1048576}"
typeset -gi REMOTE_APPROVAL_TIMEOUT="${ZCODER_REMOTE_APPROVAL_TIMEOUT:-300}"
typeset -gF REMOTE_CLIENT_NEXT_MODEL_POLL=0.0
typeset -grF REMOTE_CLIENT_MODEL_POLL_INTERVAL=0.5

typeset -g REMOTE_REQUEST_METHOD=""
typeset -g REMOTE_REQUEST_TARGET=""
typeset -g REMOTE_REQUEST_BODY=""
typeset -g REMOTE_REQUEST_AUTHORIZATION=""

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

remote_load_token() {
  local path="$1" token=""
  local -A token_stat=()
  REMOTE_ERROR=""
  [[ -n "$path" ]] || { REMOTE_ERROR="--token-file is required for remote mode"; return 1; }
  path="${path:A}"
  [[ -f "$path" && -r "$path" ]] || { REMOTE_ERROR="token file is not readable: $path"; return 1; }
  # The token is a bearer credential. Refuse to launch unless the file is
  # private: owned by the invoking user and with no group or other permission
  # bits (0600, or stricter such as 0400).
  if ! zmodload -F zsh/stat b:zstat 2>/dev/null || ! zstat -H token_stat -- "$path" 2>/dev/null; then
    REMOTE_ERROR="could not inspect token file ownership and permissions: $path"
    return 1
  fi
  if [[ "${token_stat[uid]}" != "$EUID" ]]; then
    REMOTE_ERROR="token file must be owned by the current user: $path"
    return 1
  fi
  if (( token_stat[mode] & 8#077 )); then
    REMOTE_ERROR="token file is accessible to group or others; make it private with: chmod 600 $path"
    return 1
  fi
  token="${mapfile[$path]}"
  while [[ "$token" == *$'\n' || "$token" == *$'\r' ]]; do token="${token[1,-2]}"; done
  if (( ${#token} < 32 )) || [[ "$token" != [A-Za-z0-9._~-]## ]]; then
    REMOTE_ERROR="token must contain at least 32 URL-safe characters"
    return 1
  fi
  REMOTE_TOKEN_FILE="$path"
  REMOTE_TOKEN="$token"
}

remote_client_auth_header() {
  REPLY="Authorization: Bearer ${REMOTE_TOKEN}"$'\r\n'
}

remote_client_request() {
  local method="$1" path="$2" payload="${3:-}" error_body=""
  remote_client_auth_header
  if ! http_request "$method" "$path" "$payload" "$REMOTE_ENDPOINT" "$REPLY"; then
    error_body="$HTTP_BODY"
    if [[ -n "$error_body" ]] && json_parse_flat_object "$error_body" && [[ -n "${JSON_OBJECT[error]:-}" ]]; then
      REMOTE_ERROR="${JSON_OBJECT[error]}"
    else
      REMOTE_ERROR="${HTTP_ERROR//Ollama/remote server}"
    fi
    return 1
  fi
  return 0
}

remote_client_handshake() {
  local protocol="" server_name="" workspace="" model="" profile="" command_policy=""
  remote_load_token "$REMOTE_TOKEN_FILE" || return 1
  remote_client_request GET /v1/hello || return 1
  json_parse_flat_object "$HTTP_BODY" || { REMOTE_ERROR="invalid server handshake: ${JSON_ERROR:-parse error}"; return 1; }
  protocol="${JSON_OBJECT[protocol]:-}"
  server_name="${JSON_OBJECT[server_name]:-Remote zcoder}"
  workspace="${JSON_OBJECT[workspace]:-remote-workspace}"
  model="${JSON_OBJECT[model]:-unknown}"
  profile="${JSON_OBJECT[profile]:-coding}"
  command_policy="${JSON_OBJECT[command_policy]:-ask}"
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
}

_remote_client_parse_model_status() {
  if ! json_parse_flat_object "$HTTP_BODY"; then
    REMOTE_ERROR="invalid remote model status: ${JSON_ERROR:-parse error}"
    return 1
  fi
  REMOTE_MODEL_STATUS="${JSON_OBJECT[model_status]:-unknown}"
  REMOTE_MODEL_ERROR="${JSON_OBJECT[model_error]:-}"
  [[ "$REMOTE_MODEL_STATUS" == ready || "$REMOTE_MODEL_STATUS" == warming || "$REMOTE_MODEL_STATUS" == error ]] || {
    REMOTE_ERROR="invalid remote model status: ${REMOTE_MODEL_STATUS}"
    return 1
  }
}

remote_client_model_poll() {
  local -i force="${1:-0}"
  local -F now=$EPOCHREALTIME
  [[ "$REMOTE_MODEL_STATUS" == warming ]] || return 0
  if (( ! force && now < REMOTE_CLIENT_NEXT_MODEL_POLL )); then
    return 0
  fi
  REMOTE_CLIENT_NEXT_MODEL_POLL=$(( now + REMOTE_CLIENT_MODEL_POLL_INTERVAL ))
  if ! remote_client_request GET /v1/model; then
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
  if [[ "$REMOTE_MODEL_STATUS" == unmanaged ]]; then
    agent_set_status "Ready"
    return 0
  fi
  agent_set_status "Checking Model"
  if ! remote_client_request POST /v1/model/ensure '{}'; then
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
        agent_emit system "⏹ Prompt cancelled before it was sent; remote model warm-up continues."
        agent_set_status "Warming Up"
        return 130
      fi
    else
      zselect -t 1 2>/dev/null
    fi
    remote_client_model_poll 1 || return 1
  done
  if [[ "$REMOTE_MODEL_STATUS" == ready ]]; then
    agent_set_status "Ready"
    return 0
  fi
  REMOTE_ERROR="${REMOTE_MODEL_ERROR:-remote model warm-up failed}"
  agent_set_status "Warm-up Failed"
  return 1
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
  remote_client_request POST /v1/cancel '{}' >/dev/null 2>&1 || true
  agent_emit system "⏹ Remote response generation stopped."
  agent_set_status "Stopped"
}

remote_client_user_turn() {
  local user_content="$1" prompt_json="" event="" role="" content="" thinking="" event_status=""
  local approval_id="" command_text="" answer="n" decision="n" approval_json="" exit_code="0"
  local -i poll_status=0
  AGENT_LAST_RESPONSE=""
  if (( ${UI_ACTIVE:-0} )); then
    ui_append_message user "$user_content"
    ui_refresh_all
  fi
  json_quote "$user_content"; prompt_json="$REPLY"
  remote_client_model_ensure
  poll_status=$?
  if (( poll_status != 0 )); then
    (( poll_status == 130 )) && return 130
    agent_emit error "Remote model preparation failed: ${REMOTE_MODEL_ERROR:-$REMOTE_ERROR}"
    return 1
  fi
  agent_set_status "Connecting"
  while ! remote_client_request POST /v1/turn "{\"prompt\":${prompt_json}}"; do
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
  while true; do
    if ! remote_client_request GET "/v1/events?after=${REMOTE_CLIENT_EVENT_CURSOR}"; then
      agent_emit error "Remote event request failed: $REMOTE_ERROR"
      agent_set_status "Error"
      return 1
    fi
    if ! json_parse_flat_object "$HTTP_BODY"; then
      agent_emit error "Invalid remote event: ${JSON_ERROR:-parse error}"
      agent_set_status "Error"
      return 1
    fi
    event="${JSON_OBJECT[event]:-}"
    if [[ "${JSON_OBJECT[seq]:-}" == <0-> ]]; then
      REMOTE_CLIENT_EVENT_CURSOR="${JSON_OBJECT[seq]}"
    fi
    role="${JSON_OBJECT[role]:-}"
    content="${JSON_OBJECT[content]:-}"
    thinking="${JSON_OBJECT[thinking]:-}"
    event_status="${JSON_OBJECT[status]:-}"
    approval_id="${JSON_OBJECT[id]:-}"
    command_text="${JSON_OBJECT[command]:-}"
    exit_code="${JSON_OBJECT[exit_code]:-0}"
    case "$event" in
      none)
        if (( ${UI_ACTIVE:-0} && $+functions[ui_poll_remote_turn] )); then
          ui_poll_remote_turn
          poll_status=$?
          if (( poll_status == 130 )); then
            remote_client_cancel_turn
            return 130
          fi
        else
          zselect -t 1 2>/dev/null
        fi
        ;;
      message|status)
        _remote_client_emit_event "$event" "$role" "$content" "$thinking" "$event_status"
        ;;
      approval_required)
        if (( $+functions[ui_confirm_command] )); then
          ui_confirm_command "$command_text"
          answer="$REPLY"
        fi
        case "${(L)answer}" in
          y|yes|once) decision="y" ;;
          a|always|session) decision="a" ;;
          *) decision="n" ;;
        esac
        json_quote "$approval_id"; approval_id="$REPLY"
        json_quote "$decision"; decision="$REPLY"
        approval_json="{\"id\":${approval_id},\"decision\":${decision}}"
        if ! remote_client_request POST /v1/approval "$approval_json"; then
          agent_emit error "Could not send command approval: $REMOTE_ERROR"
          remote_client_cancel_turn
          return 1
        fi
        ;;
      complete)
        [[ "$exit_code" == <0-255> ]] || exit_code=1
        (( exit_code == 0 )) && agent_set_status "Ready" || agent_set_status "Error"
        return "$exit_code"
        ;;
      *)
        agent_emit error "Unknown remote event: ${event:-missing event type}"
        return 1
        ;;
    esac
  done
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
  json_quote "$role"; role_json="$REPLY"
  json_quote "$content"; content_json="$REPLY"
  json_quote "$thinking"; thinking_json="$REPLY"
  _remote_server_publish_json "{\"event\":\"message\",\"role\":${role_json},\"content\":${content_json},\"thinking\":${thinking_json}}"
}

remote_server_emit_status() {
  local status_json=""
  json_quote "$1"; status_json="$REPLY"
  _remote_server_publish_json "{\"event\":\"status\",\"status\":${status_json}}"
}

remote_server_worker_emit() {
  remote_server_emit_message "$@"
}

remote_server_worker_status() {
  remote_server_emit_status "$1"
}

_remote_server_model_status_json() {
  local status_json="" error_json=""
  json_quote "$REMOTE_MODEL_STATUS"; status_json="$REPLY"
  json_quote "$REMOTE_MODEL_ERROR"; error_json="$REPLY"
  REPLY="{\"model_status\":${status_json},\"model_error\":${error_json}}"
}

_remote_server_model_poll() {
  local response="" error=""
  local -i request_status=0 parse_status=0
  [[ "$REMOTE_MODEL_STATUS" == warming ]] || return 0
  http_async_ready || return 1
  http_async_collect
  request_status=$?
  response="$HTTP_BODY"
  if (( request_status == 0 )); then
    json_parse_ollama_response "$response" || parse_status=$?
  fi
  if (( request_status == 0 && parse_status == 0 )) && [[ -z "$JSON_RESPONSE_ERROR" ]]; then
    REMOTE_MODEL_STATUS="ready"
    REMOTE_MODEL_ERROR=""
    agent_context_refresh_after_response
    zcoder_debug remote_warmup_complete "model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST}"
    return 0
  fi
  if (( request_status != 0 )); then
    error="${HTTP_ERROR:-Ollama warm-up request failed}"
  elif (( parse_status != 0 )); then
    error="${JSON_ERROR:-invalid Ollama warm-up response}"
  else
    error="${JSON_RESPONSE_ERROR:-Ollama warm-up failed}"
  fi
  REMOTE_MODEL_STATUS="error"
  REMOTE_MODEL_ERROR="$error"
  zcoder_debug remote_warmup_error "model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} status=$request_status error=${(qqq)error}"
  return 2
}

_remote_server_model_start_warmup() {
  local payload=""
  agent_build_warmup_payload
  payload="$REPLY"
  if ! http_async_start POST /api/chat "$payload" "$OLLAMA_HOST"; then
    REMOTE_MODEL_STATUS="error"
    REMOTE_MODEL_ERROR="${HTTP_ERROR:-could not start Ollama warm-up}"
    zcoder_debug remote_warmup_start_error "model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} error=${(qqq)REMOTE_MODEL_ERROR}"
    return 1
  fi
  REMOTE_MODEL_STATUS="warming"
  REMOTE_MODEL_ERROR=""
  zcoder_debug remote_warmup_start "model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} payload_chars=${#payload}"
}

# Check residency only at meaningful boundaries: initial connection and just
# before a turn. Status polling merely collects an existing warm-up so several
# configured servers do not continually fight over constrained model memory.
_remote_server_model_ensure() {
  local -i force="${1:-0}" poll_status=0
  if [[ "$REMOTE_MODEL_STATUS" == warming ]]; then
    _remote_server_model_poll
    poll_status=$?
    (( poll_status == 1 )) && return 1
    (( poll_status == 2 )) && return 2
    (( force )) || return 0
  fi
  if (( ! force )) && [[ "$REMOTE_MODEL_STATUS" == ready ]]; then
    return 0
  fi
  REMOTE_MODEL_STATUS="checking"
  REMOTE_MODEL_ERROR=""
  if ollama_get_running_context "$ZCODER_MODEL" "$OLLAMA_HOST"; then
    REMOTE_MODEL_STATUS="ready"
    AGENT_CONTEXT_WINDOW="$OLLAMA_RUNNING_CONTEXT"
    AGENT_CONTEXT_MODEL="$ZCODER_MODEL"
    return 0
  fi
  if [[ -n "$HTTP_ERROR" ]]; then
    REMOTE_MODEL_STATUS="error"
    REMOTE_MODEL_ERROR="$HTTP_ERROR"
    zcoder_debug remote_model_check_error "model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} error=${(qqq)REMOTE_MODEL_ERROR}"
    return 2
  fi
  _remote_server_model_start_warmup || return 2
  return 1
}

remote_server_request_approval() {
  local command_text="$1" approval_id="${REMOTE_TURN_ID}_${RANDOM}" id_json="" command_json=""
  local pending="$REMOTE_RUNTIME_DIR/pending_approval" response="$REMOTE_RUNTIME_DIR/approvals/${approval_id}.response"
  local decision="n"
  local -F deadline=$(( EPOCHREALTIME + REMOTE_APPROVAL_TIMEOUT ))
  json_quote "$approval_id"; id_json="$REPLY"
  json_quote "$command_text"; command_json="$REPLY"
  mapfile[$pending]="$approval_id" || { REPLY="n"; return 1; }
  _remote_server_publish_json "{\"event\":\"approval_required\",\"id\":${id_json},\"command\":${command_json}}" || {
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
    "$REMOTE_RUNTIME_DIR"/{pending_approval,pending_prompt,worker.done}(N) 2>/dev/null
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

_remote_http_reason() {
  case "$1" in
    200) REPLY="OK" ;; 202) REPLY="Accepted" ;; 400) REPLY="Bad Request" ;;
    401) REPLY="Unauthorized" ;; 404) REPLY="Not Found" ;; 409) REPLY="Conflict" ;;
    413) REPLY="Payload Too Large" ;; 500) REPLY="Internal Server Error" ;;
    503) REPLY="Service Unavailable" ;;
    *) REPLY="Error" ;;
  esac
}

_remote_http_send() {
  setopt localoptions nomultibyte
  local fd="$1" status_code="$2" body="${3:-}" reason="" response=""
  local -i body_bytes
  _remote_http_reason "$status_code"; reason="$REPLY"
  _http_byte_length "$body"; body_bytes=$REPLY
  response="HTTP/1.1 ${status_code} ${reason}"$'\r\n'\
"Content-Type: application/json"$'\r\n'\
"Cache-Control: no-store"$'\r\n'\
"Connection: close"$'\r\n'\
"Content-Length: ${body_bytes}"$'\r\n\r\n'"${body}"
  syswrite -o "$fd" "$response" 2>/dev/null
}

_remote_http_error() {
  local fd="$1" status_code="$2" message_json=""
  json_quote "$3"; message_json="$REPLY"
  _remote_http_send "$fd" "$status_code" "{\"error\":${message_json}}"
}

_remote_http_read_request() {
  setopt localoptions nomultibyte
  local fd="$1" raw="" chunk="" header="" request_line="" line="" key="" value="" body=""
  local -a lines=()
  local -i content_length=0 header_bytes=0
  REMOTE_REQUEST_METHOD=""
  REMOTE_REQUEST_TARGET=""
  REMOTE_REQUEST_BODY=""
  REMOTE_REQUEST_AUTHORIZATION=""
  while [[ "$raw" != *$'\r\n\r\n'* ]]; do
    sysread -i "$fd" -s 32768 -t 10 chunk 2>/dev/null || { REMOTE_ERROR="request header timed out"; return 1; }
    raw+="$chunk"
    (( ${#raw} <= 65536 )) || { REMOTE_ERROR="request header is too large"; return 2; }
  done
  header="${raw%%$'\r\n\r\n'*}"
  header_bytes=$(( ${#header} + 4 ))
  body="${raw[$(( header_bytes + 1 )),-1]}"
  lines=("${(@f)${header//$'\r'/}}")
  request_line="${lines[1]:-}"
  REMOTE_REQUEST_METHOD="${request_line%% *}"
  request_line="${request_line#* }"
  REMOTE_REQUEST_TARGET="${request_line%% *}"
  [[ -n "$REMOTE_REQUEST_METHOD" && -n "$REMOTE_REQUEST_TARGET" && "$request_line" == *' HTTP/'* ]] || {
    REMOTE_ERROR="malformed HTTP request line"
    return 1
  }
  for line in "${lines[@]:1}"; do
    [[ "$line" == *:* ]] || continue
    key="${(L)${line%%:*}}"
    value="${line#*:}"
    value="${value##[[:space:]]#}"
    value="${value%%[[:space:]]#}"
    case "$key" in
      content-length)
        [[ "$value" == <0-> ]] || { REMOTE_ERROR="invalid Content-Length"; return 1; }
        content_length="$value"
        ;;
      authorization) REMOTE_REQUEST_AUTHORIZATION="$value" ;;
    esac
  done
  (( content_length <= REMOTE_MAX_REQUEST_BYTES )) || { REMOTE_ERROR="request body is too large"; return 2; }
  while (( ${#body} < content_length )); do
    sysread -i "$fd" -s 32768 -t 10 chunk 2>/dev/null || { REMOTE_ERROR="request body timed out"; return 1; }
    body+="$chunk"
  done
  REMOTE_REQUEST_BODY="${body[1,$content_length]}"
}

_remote_server_reap_worker() {
  local pid="${mapfile[$REMOTE_RUNTIME_DIR/active.pid]:-}"
  if [[ -f "$REMOTE_RUNTIME_DIR/worker.done" && "$pid" == <1-> ]]; then
    wait "$pid" 2>/dev/null || true
    zf_rm -f "$REMOTE_RUNTIME_DIR/active.pid" "$REMOTE_RUNTIME_DIR/worker.done" 2>/dev/null
  elif [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    zf_rm -f "$REMOTE_RUNTIME_DIR/active.pid" 2>/dev/null
  fi
}

_remote_server_turn_worker() {
  local prompt="$1" session_id="$2" saved_policy="" exit_code=0
  trap 'mcp_shutdown_all >/dev/null 2>&1 || true' EXIT
  trap 'exit 130' INT TERM HUP
  REMOTE_SERVER_WORKER=1
  UI_ACTIVE=0
  STATE_ENABLED=0
  state_load_session "$session_id" || {
    remote_server_emit_message error "Could not load the remote session."
    _remote_server_publish_json '{"event":"complete","exit_code":1}'
    mapfile[$REMOTE_RUNTIME_DIR/worker.done]="1"
    return 1
  }
  STATE_ENABLED=1
  saved_policy="${mapfile[$REMOTE_RUNTIME_DIR/command_policy]:-$ZCODER_COMMAND_POLICY}"
  if [[ "$ZCODER_PROFILE" == coding && "$saved_policy" == allow ]]; then
    ZCODER_COMMAND_POLICY="allow"
  fi
  state_note_user "$prompt"
  agent_user_turn "$prompt" || exit_code=$?
  state_save_session || true
  mapfile[$REMOTE_RUNTIME_DIR/command_policy]="$ZCODER_COMMAND_POLICY" || true
  _remote_server_publish_json "{\"event\":\"complete\",\"exit_code\":${exit_code}}"
  mapfile[$REMOTE_RUNTIME_DIR/worker.done]="$exit_code"
  return "$exit_code"
}

_remote_server_start_turn() {
  local prompt="$1" pid=""
  REMOTE_TURN_ID="${EPOCHSECONDS}_${RANDOM}"
  _remote_server_clear_turn_runtime
  (_remote_server_turn_worker "$prompt" "$REMOTE_SESSION_ID") &
  pid=$!
  mapfile[$REMOTE_RUNTIME_DIR/active.pid]="$pid" || { kill -TERM "$pid" 2>/dev/null; return 1; }
  REPLY="$REMOTE_TURN_ID"
}

_remote_server_queue_turn() {
  local prompt="$1"
  REMOTE_TURN_ID="${EPOCHSECONDS}_${RANDOM}"
  _remote_server_clear_turn_runtime
  mapfile[$REMOTE_RUNTIME_DIR/pending_prompt]="$prompt" || return 1
  REPLY="$REMOTE_TURN_ID"
}

_remote_server_progress_pending_turn() {
  local prompt=""
  [[ -f "$REMOTE_RUNTIME_DIR/pending_prompt" ]] || return 0
  _remote_server_model_poll || true
  if [[ "$REMOTE_MODEL_STATUS" == ready ]]; then
    prompt="${mapfile[$REMOTE_RUNTIME_DIR/pending_prompt]}"
    zf_rm -f "$REMOTE_RUNTIME_DIR/pending_prompt" 2>/dev/null
    _remote_server_start_turn "$prompt" || {
      remote_server_emit_message error "Could not start the prepared remote turn."
      _remote_server_publish_json '{"event":"complete","exit_code":1}'
      return 1
    }
  elif [[ "$REMOTE_MODEL_STATUS" == error ]]; then
    zf_rm -f "$REMOTE_RUNTIME_DIR/pending_prompt" 2>/dev/null
    remote_server_emit_message error "Remote model preparation failed: ${REMOTE_MODEL_ERROR:-unknown error}"
    _remote_server_publish_json '{"event":"complete","exit_code":1}'
    return 1
  fi
}

_remote_server_cancel_turn() {
  local pid="${mapfile[$REMOTE_RUNTIME_DIR/active.pid]:-}"
  if [[ -f "$REMOTE_RUNTIME_DIR/pending_prompt" ]]; then
    zf_rm -f "$REMOTE_RUNTIME_DIR/pending_prompt" 2>/dev/null
    remote_server_emit_status "Stopped"
    _remote_server_publish_json '{"event":"complete","exit_code":130}'
    return 0
  fi
  [[ "$pid" == <1-> ]] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
  fi
  zf_rm -f "$REMOTE_RUNTIME_DIR/active.pid" "$REMOTE_RUNTIME_DIR/pending_approval" 2>/dev/null
  if [[ ! -f "$REMOTE_RUNTIME_DIR/worker.done" ]]; then
    remote_server_emit_status "Stopped"
    _remote_server_publish_json '{"event":"complete","exit_code":130}'
  fi
  zf_rm -f "$REMOTE_RUNTIME_DIR/worker.done" 2>/dev/null
}

_remote_server_handle_connection() {
  local fd="$1" read_status=0 target="" after="0" prompt="" turn_json="" id="" decision=""
  _remote_http_read_request "$fd"
  read_status=$?
  if (( read_status != 0 )); then
    (( read_status == 2 )) && _remote_http_error "$fd" 413 "$REMOTE_ERROR" || _remote_http_error "$fd" 400 "$REMOTE_ERROR"
    return
  fi
  if [[ "$REMOTE_REQUEST_AUTHORIZATION" != "Bearer ${REMOTE_TOKEN}" ]]; then
    _remote_http_error "$fd" 401 "authentication required"
    return
  fi
  _remote_server_reap_worker
  target="$REMOTE_REQUEST_TARGET"
  case "$REMOTE_REQUEST_METHOD:$target" in
    GET:/v1/hello)
      local name_json="" workspace_json="" model_json="" profile_json="" policy_json="" model_status_json="" model_error_json=""
      local effective_policy="${mapfile[$REMOTE_RUNTIME_DIR/command_policy]:-$ZCODER_COMMAND_POLICY}"
      _remote_server_model_ensure 1 || true
      json_quote "$REMOTE_SERVER_NAME"; name_json="$REPLY"
      json_quote "${ZCODER_WORKSPACE:A}"; workspace_json="$REPLY"
      json_quote "$ZCODER_MODEL"; model_json="$REPLY"
      json_quote "$ZCODER_PROFILE"; profile_json="$REPLY"
      json_quote "$effective_policy"; policy_json="$REPLY"
      json_quote "$REMOTE_MODEL_STATUS"; model_status_json="$REPLY"
      json_quote "$REMOTE_MODEL_ERROR"; model_error_json="$REPLY"
      _remote_http_send "$fd" 200 "{\"protocol\":1,\"server_name\":${name_json},\"workspace\":${workspace_json},\"model\":${model_json},\"profile\":${profile_json},\"command_policy\":${policy_json},\"model_status\":${model_status_json},\"model_error\":${model_error_json}}"
      ;;
    GET:/v1/model)
      _remote_server_model_poll || true
      _remote_server_model_status_json
      _remote_http_send "$fd" 200 "$REPLY"
      ;;
    POST:/v1/model/ensure)
      _remote_server_model_ensure 1 || true
      _remote_server_model_status_json
      _remote_http_send "$fd" 200 "$REPLY"
      ;;
    POST:/v1/turn)
      if [[ -f "$REMOTE_RUNTIME_DIR/active.pid" || -f "$REMOTE_RUNTIME_DIR/pending_prompt" ]]; then
        _remote_http_error "$fd" 409 "a remote turn is already running"
        return
      fi
      if ! json_parse_flat_object "$REMOTE_REQUEST_BODY"; then
        _remote_http_error "$fd" 400 "invalid turn request: ${JSON_ERROR:-parse error}"
        return
      fi
      prompt="${JSON_OBJECT[prompt]:-}"
      [[ -n "$prompt" && "${JSON_OBJECT_TYPES[prompt]:-}" == string ]] || {
        _remote_http_error "$fd" 400 "prompt must be a non-empty string"
        return
      }
      _remote_server_model_ensure 1 || true
      if [[ "$REMOTE_MODEL_STATUS" == warming ]]; then
        if ! _remote_server_queue_turn "$prompt"; then
          _remote_http_error "$fd" 500 "could not queue the remote turn during model warm-up"
          return
        fi
        json_quote "$REPLY"; turn_json="$REPLY"
        _remote_http_send "$fd" 202 "{\"turn_id\":${turn_json},\"model_status\":\"warming\"}"
        return
      elif [[ "$REMOTE_MODEL_STATUS" == error ]]; then
        _remote_http_error "$fd" 503 "${REMOTE_MODEL_ERROR:-model preparation failed}"
        return
      fi
      if ! _remote_server_start_turn "$prompt"; then
        _remote_http_error "$fd" 500 "could not start the remote turn"
        return
      fi
      json_quote "$REPLY"; turn_json="$REPLY"
      _remote_http_send "$fd" 202 "{\"turn_id\":${turn_json}}"
      ;;
    GET:/v1/events\?after=*)
      after="${target#*/v1/events\?after=}"
      [[ "$after" == <0-> ]] || { _remote_http_error "$fd" 400 "after must be a non-negative integer"; return; }
      _remote_server_progress_pending_turn || true
      _remote_server_next_event "$after"
      _remote_http_send "$fd" 200 "$REPLY"
      ;;
    POST:/v1/approval)
      if ! json_parse_flat_object "$REMOTE_REQUEST_BODY"; then
        _remote_http_error "$fd" 400 "invalid approval response"
        return
      fi
      id="${JSON_OBJECT[id]:-}"
      decision="${JSON_OBJECT[decision]:-}"
      if [[ -z "$id" || "$id" != "${mapfile[$REMOTE_RUNTIME_DIR/pending_approval]:-}" || "$id" != [0-9_]## ]]; then
        _remote_http_error "$fd" 409 "approval is missing, expired, or does not match"
        return
      fi
      [[ "$decision" == y || "$decision" == a || "$decision" == n ]] || {
        _remote_http_error "$fd" 400 "decision must be y, a, or n"
        return
      }
      if [[ "$decision" == a && "$ZCODER_PROFILE" == coding ]]; then
        mapfile[$REMOTE_RUNTIME_DIR/command_policy]="allow"
      fi
      mapfile[$REMOTE_RUNTIME_DIR/approvals/${id}.response.tmp]="$decision"
      zf_mv -f "$REMOTE_RUNTIME_DIR/approvals/${id}.response.tmp" "$REMOTE_RUNTIME_DIR/approvals/${id}.response" 2>/dev/null || {
        _remote_http_error "$fd" 500 "could not publish approval response"
        return
      }
      _remote_http_send "$fd" 200 '{"ok":true}'
      ;;
    POST:/v1/cancel)
      if _remote_server_cancel_turn; then
        _remote_http_send "$fd" 200 '{"ok":true}'
      else
        _remote_http_error "$fd" 409 "no remote turn is running"
      fi
      ;;
    *) _remote_http_error "$fd" 404 "unknown endpoint" ;;
  esac
}

remote_server_stop() {
  local pid="" owner_pid=""
  local -i owns_runtime=1
  if [[ -n "$REMOTE_RUNTIME_DIR" ]]; then
    owner_pid="${mapfile[$REMOTE_RUNTIME_DIR/server.pid]:-}"
    [[ -n "$owner_pid" && "$owner_pid" != "${sysparams[pid]:-$$}" ]] && owns_runtime=0
    if (( owns_runtime )); then
      pid="${mapfile[$REMOTE_RUNTIME_DIR/active.pid]:-}"
      if [[ "$pid" == <1-> ]] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
      fi
      zf_rm -f "$REMOTE_RUNTIME_DIR/active.pid" "$REMOTE_RUNTIME_DIR/pending_prompt" \
        "$REMOTE_RUNTIME_DIR/server.pid" 2>/dev/null
    fi
  fi
  if [[ -n "$REMOTE_LISTEN_FD" ]]; then
    ztcp -c "$REMOTE_LISTEN_FD" 2>/dev/null
    REMOTE_LISTEN_FD=""
  fi
}

remote_server_main() {
  local safe_name="" client_fd="" existing_pid="" old_umask="$(umask)"
  [[ "$REMOTE_SERVER_PORT" == <1-65535> ]] || { print -u2 -- "Error: --port expects an integer from 1 through 65535"; return 2; }
  [[ -n "$REMOTE_SERVER_NAME" ]] || { print -u2 -- "Error: --server requires a non-empty name"; return 2; }
  remote_load_token "$REMOTE_TOKEN_FILE" || { print -u2 -- "Error: $REMOTE_ERROR"; return 2; }
  _remote_safe_name "$REMOTE_SERVER_NAME"; safe_name="$REPLY"
  REMOTE_RUNTIME_DIR="${ZCODER_HOME:A}/remote/${safe_name}"
  umask 077
  zf_mkdir -p "$REMOTE_RUNTIME_DIR/events" "$REMOTE_RUNTIME_DIR/approvals" 2>/dev/null || {
    umask "$old_umask"
    print -u2 -- "Error: could not create remote runtime directory: $REMOTE_RUNTIME_DIR"
    return 1
  }
  zf_chmod 700 "$REMOTE_RUNTIME_DIR" "$REMOTE_RUNTIME_DIR/events" "$REMOTE_RUNTIME_DIR/approvals" 2>/dev/null || true
  umask "$old_umask"
  existing_pid="${mapfile[$REMOTE_RUNTIME_DIR/server.pid]:-}"
  if [[ "$existing_pid" == <1-> ]] && kill -0 "$existing_pid" 2>/dev/null; then
    print -u2 -- "Error: remote server '$REMOTE_SERVER_NAME' is already running with pid $existing_pid"
    return 1
  fi
  mapfile[$REMOTE_RUNTIME_DIR/server.pid]="${sysparams[pid]:-$$}" || {
    print -u2 -- "Error: could not acquire the remote server runtime"
    return 1
  }
  _remote_server_clear_turn_runtime
  zf_rm -f "$REMOTE_RUNTIME_DIR/active.pid" 2>/dev/null
  mapfile[$REMOTE_RUNTIME_DIR/command_policy]="$ZCODER_COMMAND_POLICY" || {
    print -u2 -- "Error: could not initialize remote command policy"
    return 1
  }
  ZCODER_SESSIONS_DIR="$REMOTE_RUNTIME_DIR/sessions"
  if ! state_init; then
    print -u2 -- "Error: could not initialize remote session storage"
    return 1
  fi
  REMOTE_SESSION_ID="$CURRENT_SESSION_ID"
  # The long-lived listener must not overwrite worker-updated session data on exit.
  STATE_ENABLED=0
  if ! ztcp -l "$REMOTE_SERVER_PORT"; then
    print -u2 -- "Error: could not listen on TCP port $REMOTE_SERVER_PORT"
    return 1
  fi
  REMOTE_LISTEN_FD="$REPLY"
  print -u2 -- "${ZCODER_NAME} server '${REMOTE_SERVER_NAME}' listening on port ${REMOTE_SERVER_PORT}"
  print -u2 -- "Workspace: ${ZCODER_WORKSPACE:A}"
  print -u2 -- "Model: ${ZCODER_MODEL} (${ZCODER_PROFILE})"
  print -u2 -- "Transport: authenticated plain HTTP; use only on a trusted LAN or through a secure tunnel"
  while (( RUNNING )); do
    if ! ztcp -a "$REMOTE_LISTEN_FD" 2>/dev/null; then
      (( RUNNING )) && print -u2 -- "Error: failed to accept remote connection"
      break
    fi
    client_fd="$REPLY"
    _remote_server_handle_connection "$client_fd"
    ztcp -c "$client_fd" 2>/dev/null
  done
  remote_server_stop
}

# Native Zsh HTTP listener and authenticated remote-server request dispatch.

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
  # Cached events may contain JSON serialized before UTF-8 repair was added.
  zjson_utf8_repair "$body"; body="$REPLY"
  _http_byte_length "$body"; body_bytes=$REPLY
  response="HTTP/1.1 ${status_code} ${reason}"$'\r\n'\
"Content-Type: application/json"$'\r\n'\
"Cache-Control: no-store"$'\r\n'\
"Connection: close"$'\r\n'\
"Content-Length: ${body_bytes}"$'\r\n\r\n'"${body}"
  if [[ -n "${REMOTE_CONNECTION_PHASE[$fd]:-}" ]]; then
    _remote_server_connection_send "$fd" "$response"
    return $?
  fi
  zcoder_syswrite_all "$fd" "$response"
}

_remote_http_error() {
  local fd="$1" status_code="$2" message_json=""
  zjson_quote "$3"; message_json="$REPLY"
  _remote_http_send "$fd" "$status_code" "{\"error\":${message_json}}"
}

_remote_http_parse_headers() {
  setopt localoptions extendedglob nomultibyte
  local header="$1" request_line="" line="" key="" value="" content_length=0
  local expected_authorization="${2:-}"
  local maximum="$REMOTE_MAX_REQUEST_BYTES"
  local -a lines=()
  REMOTE_ERROR=""
  REMOTE_REQUEST_METHOD=""
  REMOTE_REQUEST_TARGET=""
  REMOTE_REQUEST_BODY=""
  REMOTE_REQUEST_AUTHORIZATION=""
  REMOTE_REQUEST_LENGTH=0
  (( ${#header} + 4 <= 65536 )) || { REMOTE_ERROR="request header is too large"; return 2; }
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
        # Bound decimal text before arithmetic so a huge length cannot wrap
        # around the integer limit and bypass the per-connection memory cap.
        content_length="${value##0#}"
        content_length="${content_length:-0}"
        ;;
      authorization) REMOTE_REQUEST_AUTHORIZATION="$value" ;;
    esac
  done
  if [[ -n "$expected_authorization" && "$REMOTE_REQUEST_AUTHORIZATION" != "$expected_authorization" ]]; then
    REMOTE_ERROR="authentication required"
    return 3
  fi
  if (( ${#content_length} > ${#maximum} )) ||
      { (( ${#content_length} == ${#maximum} )) && [[ "$content_length" > "$maximum" ]]; }; then
    REMOTE_ERROR="request body is too large"
    return 2
  fi
  REMOTE_REQUEST_LENGTH=$(( 10#$content_length ))
}

# Blocking convenience reader for protocol fixtures and direct dispatch tests.
# The production listener uses the same header parser with incremental I/O.
_remote_http_read_request() {
  setopt localoptions nomultibyte
  local fd="$1" expected_authorization="${2:-}" raw="" chunk="" header="" body=""
  local -i content_length=0 header_bytes=0
  zmodload zsh/datetime || { REMOTE_ERROR="could not load request clock"; return 1; }
  local -F deadline=$(( EPOCHREALTIME + REMOTE_SERVER_READ_TIMEOUT )) remaining=0
  REMOTE_REQUEST_BODY=""
  while [[ "$raw" != *$'\r\n\r\n'* ]]; do
    remaining=$(( deadline - EPOCHREALTIME ))
    if (( remaining <= 0 )) || ! sysread -i "$fd" -s 32768 -t "$remaining" chunk 2>/dev/null; then
      REMOTE_ERROR="request header timed out"
      return 1
    fi
    raw+="$chunk"
    [[ "$raw" == *$'\r\n\r\n'* ]] || (( ${#raw} <= 65536 )) || {
      REMOTE_ERROR="request header is too large"; return 2
    }
  done
  header="${raw%%$'\r\n\r\n'*}"
  header_bytes=$(( ${#header} + 4 ))
  body="${raw[$(( header_bytes + 1 )),-1]}"
  _remote_http_parse_headers "$header" "$expected_authorization" || return $?
  content_length=$REMOTE_REQUEST_LENGTH
  while (( ${#body} < content_length )); do
    remaining=$(( deadline - EPOCHREALTIME ))
    if (( remaining <= 0 )) || ! sysread -i "$fd" -s 32768 -t "$remaining" chunk 2>/dev/null; then
      REMOTE_ERROR="request body timed out"
      return 1
    fi
    body+="$chunk"
  done
  (( EPOCHREALTIME < deadline )) || { REMOTE_ERROR="request timed out"; return 1; }
  REMOTE_REQUEST_BODY="${body[1,$content_length]}"
}

_remote_server_reap_worker() {
  local pid="${mapfile[$REMOTE_RUNTIME_DIR/active.pid]:-}"
  local CURRENT_SESSION_ID="$REMOTE_SESSION_ID" INPUT_QUEUE_TURN_ID="$REMOTE_TURN_ID"
  if [[ -f "$REMOTE_RUNTIME_DIR/worker.done" && "$pid" == <1-> ]]; then
    wait "$pid" 2>/dev/null || true
    input_queue_close true || true
    zf_rm -f "$REMOTE_RUNTIME_DIR/active.pid" "$REMOTE_RUNTIME_DIR/worker.done" 2>/dev/null
  elif [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    input_queue_close true || true
    zf_rm -f "$REMOTE_RUNTIME_DIR/active.pid" 2>/dev/null
  fi
}

_remote_server_turn_worker() {
  local prompt="$1" session_id="$2" connection_fd="${3:-}" structured_events="${4:-0}" queued_continuation="${5:-0}" saved_policy="" exit_code=0
  trap 'mcp_shutdown_all >/dev/null 2>&1 || true' EXIT
  trap 'exit 130' INT TERM HUP
  _http_close_inherited_fds "$REMOTE_LISTEN_FD" "$connection_fd" "${(@k)REMOTE_CONNECTION_PHASE}"
  REMOTE_CONNECTION_PHASE=()
  REMOTE_LISTEN_FD=""
  REMOTE_SERVER_WORKER=1
  REMOTE_SERVER_TOOL_SEQUENCE=0
  REMOTE_SERVER_TOOL_CALL_ID=""
  [[ "$structured_events" == 1 ]] && REMOTE_STRUCTURED_TOOL_EVENTS=1 || REMOTE_STRUCTURED_TOOL_EVENTS=0
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
  if (( queued_continuation )); then
    agent_add_context_message 'The user interrupted the previous operation to send the queued request that follows. Completed side effects were not rolled back; inspect current state before repeating any action.'
    _agent_run_turn '' queue_resume || exit_code=$?
  elif [[ "$prompt" == '/queue resume' ]]; then
    input_queue_command resume || exit_code=$?
  elif [[ "$prompt" == /goal || "$prompt" == /goal\ * ]]; then
    ui_append_message user "$prompt"
    goal_handle_command "$prompt" || exit_code=$?
  else
    state_note_user "$prompt"
    ui_append_message user "$prompt"
    agent_user_turn "$prompt" || exit_code=$?
  fi
  state_save_session || true
  mapfile[$REMOTE_RUNTIME_DIR/command_policy]="$ZCODER_COMMAND_POLICY" || true
  _remote_server_publish_json "{\"event\":\"complete\",\"exit_code\":${exit_code}}"
  mapfile[$REMOTE_RUNTIME_DIR/worker.done]="$exit_code"
  return "$exit_code"
}

_remote_server_start_turn() {
  local prompt="$1" connection_fd="${2:-}" structured_events="${3:-0}" pid=""
  REMOTE_TURN_ID="${4:-${EPOCHSECONDS}_${RANDOM}}"
  _remote_server_clear_turn_runtime
  mapfile[$REMOTE_RUNTIME_DIR/active_structured_events]="$structured_events" || return 1
  input_queue_open "$REMOTE_SESSION_ID" "$REMOTE_TURN_ID" || return 1
  (_remote_server_turn_worker "$prompt" "$REMOTE_SESSION_ID" "$connection_fd" "$structured_events") &
  pid=$!
  mapfile[$REMOTE_RUNTIME_DIR/active.pid]="$pid" || { kill -TERM "$pid" 2>/dev/null; return 1; }
  REPLY="$REMOTE_TURN_ID"
}

_remote_server_queue_turn() {
  local prompt="$1" structured_events="${2:-0}"
  REMOTE_TURN_ID="${EPOCHSECONDS}_${RANDOM}"
  _remote_server_clear_turn_runtime
  mapfile[$REMOTE_RUNTIME_DIR/active_structured_events]="$structured_events" || return 1
  input_queue_open "$REMOTE_SESSION_ID" "$REMOTE_TURN_ID" || return 1
  mapfile[$REMOTE_RUNTIME_DIR/pending_prompt]="$prompt" || return 1
  mapfile[$REMOTE_RUNTIME_DIR/pending_structured_events]="$structured_events" || return 1
  REPLY="$REMOTE_TURN_ID"
}

_remote_server_progress_pending_turn() {
  local connection_fd="${1:-}" prompt="" structured_events="0"
  [[ -f "$REMOTE_RUNTIME_DIR/pending_prompt" ]] || return 0
  _remote_server_model_poll || true
  if [[ "$REMOTE_MODEL_STATUS" == ready ]]; then
    prompt="${mapfile[$REMOTE_RUNTIME_DIR/pending_prompt]}"
    structured_events="${mapfile[$REMOTE_RUNTIME_DIR/pending_structured_events]:-0}"
    zf_rm -f "$REMOTE_RUNTIME_DIR/pending_prompt" "$REMOTE_RUNTIME_DIR/pending_structured_events" 2>/dev/null
    _remote_server_start_turn "$prompt" "$connection_fd" "$structured_events" "$REMOTE_TURN_ID" || {
      remote_server_emit_message error "Could not start the prepared remote turn."
      _remote_server_publish_json '{"event":"complete","exit_code":1}'
      return 1
    }
  elif [[ "$REMOTE_MODEL_STATUS" == error ]]; then
    local CURRENT_SESSION_ID="$REMOTE_SESSION_ID" INPUT_QUEUE_TURN_ID="$REMOTE_TURN_ID"
    input_queue_close true || true
    zf_rm -f "$REMOTE_RUNTIME_DIR/pending_prompt" "$REMOTE_RUNTIME_DIR/pending_structured_events" 2>/dev/null
    remote_server_emit_message error "Remote model preparation failed: ${REMOTE_MODEL_ERROR:-unknown error}"
    _remote_server_publish_json '{"event":"complete","exit_code":1}'
    return 1
  fi
}

_remote_server_cancel_turn() {
  local pid="${mapfile[$REMOTE_RUNTIME_DIR/active.pid]:-}"
  local continue_queued="${1:-false}" connection_fd="${2:-}" structured_events="${mapfile[$REMOTE_RUNTIME_DIR/active_structured_events]:-0}"
  local CURRENT_SESSION_ID="$REMOTE_SESSION_ID" INPUT_QUEUE_TURN_ID="$REMOTE_TURN_ID"
  local -i queue_result=0
  REMOTE_CANCEL_CONTINUED=0
  input_queue_close true || true
  if [[ -f "$REMOTE_RUNTIME_DIR/pending_prompt" ]]; then
    zf_rm -f "$REMOTE_RUNTIME_DIR/pending_prompt" "$REMOTE_RUNTIME_DIR/pending_structured_events" 2>/dev/null
  else
    [[ "$pid" == <1-> ]] || return 1
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null || true
    fi
  fi
  input_queue_close true || true
  # The stopped worker's latest generation is authoritative. Publish the goal
  # update through a detached loader/save so listener state stays untouched.
  state_pause_saved_goal "$REMOTE_SESSION_ID" 'remote goal execution stopped by user' ||
    remote_server_emit_message error 'Remote work stopped, but the paused goal could not be saved.'
  zf_rm -f "$REMOTE_RUNTIME_DIR/active.pid" "$REMOTE_RUNTIME_DIR/pending_approval" 2>/dev/null
  if [[ "$continue_queued" == true && ! -f "$REMOTE_RUNTIME_DIR/worker.done" ]]; then
    input_queue_close
    queue_result=$?
    if (( queue_result == 1 )) && input_queue_open "$REMOTE_SESSION_ID" "$REMOTE_TURN_ID"; then
      # Keep this turn's event cursor and queue scope. Older abandoned input
      # stays paused, and the client keeps polling the same event stream.
      (_remote_server_turn_worker '' "$REMOTE_SESSION_ID" "$connection_fd" "$structured_events" 1) &
      pid=$!
      if ! zcoder_write_text_file "$REMOTE_RUNTIME_DIR/active.pid" "$pid"; then
        kill -TERM "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
        input_queue_close true || true
        return 1
      fi
      REMOTE_CANCEL_CONTINUED=1
      return 0
    fi
  fi
  if [[ ! -f "$REMOTE_RUNTIME_DIR/worker.done" ]]; then
    remote_server_emit_status "Stopped"
    _remote_server_publish_json '{"event":"complete","exit_code":130}'
  fi
  zf_rm -f "$REMOTE_RUNTIME_DIR/worker.done" 2>/dev/null
}

_remote_server_hello_json() {
  local name_json="" workspace_json="" model_json="" profile_json="" policy_json=""
  local model_status_json="" model_error_json="" harnesses_json="" harnesses=""
  local effective_policy="${mapfile[$REMOTE_RUNTIME_DIR/command_policy]:-$ZCODER_COMMAND_POLICY}"
  if (( ! $+functions[delegate_available_csv] && $+functions[zcoder_require] )); then
    zcoder_require harnesses
  fi
  if (( $+functions[delegate_refresh_availability] )); then
    delegate_refresh_availability
    delegate_available_csv
    harnesses="$REPLY"
  fi
  zjson_quote "$REMOTE_SERVER_NAME"; name_json="$REPLY"
  zjson_quote "${ZCODER_WORKSPACE:A}"; workspace_json="$REPLY"
  zjson_quote "$ZCODER_MODEL"; model_json="$REPLY"
  zjson_quote "$ZCODER_PROFILE"; profile_json="$REPLY"
  zjson_quote "$effective_policy"; policy_json="$REPLY"
  zjson_quote "$REMOTE_MODEL_STATUS"; model_status_json="$REPLY"
  zjson_quote "$REMOTE_MODEL_ERROR"; model_error_json="$REPLY"
  zjson_quote "$harnesses"; harnesses_json="$REPLY"
  REPLY="{\"protocol\":1,\"server_name\":${name_json},\"workspace\":${workspace_json},\"model\":${model_json},\"profile\":${profile_json},\"command_policy\":${policy_json},\"model_status\":${model_status_json},\"model_error\":${model_error_json},\"harnesses\":${harnesses_json},\"sessions\":true,\"goals\":true,\"input_queue\":true}"
  _remote_server_git_json
}

_remote_server_connection_close() {
  local fd="$1" pid="${REMOTE_CONNECTION_WRITER[$1]:-}"
  if [[ -n "$pid" ]]; then
    # A response writer owns no application state or subprocesses. SIGKILL
    # also terminates a syswrite that keeps retrying interrupted writes.
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  unset "REMOTE_CONNECTION_PHASE[$fd]" "REMOTE_CONNECTION_BUFFER[$fd]" \
    "REMOTE_CONNECTION_DEADLINE[$fd]" "REMOTE_CONNECTION_LENGTH[$fd]" \
    "REMOTE_CONNECTION_METHOD[$fd]" "REMOTE_CONNECTION_TARGET[$fd]" \
    "REMOTE_CONNECTION_AUTHORIZATION[$fd]" "REMOTE_CONNECTION_WRITER[$fd]"
  ztcp -c "$fd" 2>/dev/null || true
}

_remote_server_connection_send() {
  local fd="$1" response="$2" pid=""
  [[ "${REMOTE_CONNECTION_PHASE[$fd]:-}" != writing ]] || return 1
  REMOTE_CONNECTION_PHASE[$fd]=writing
  REMOTE_CONNECTION_BUFFER[$fd]=''
  REMOTE_CONNECTION_DEADLINE[$fd]=$(( EPOCHREALTIME + REMOTE_SERVER_WRITE_TIMEOUT ))
  # Only network output runs in a child. The handler has already made its
  # state changes in the listener. No completion-file protocol is needed.
  (
    trap - EXIT INT TERM HUP WINCH PIPE
    local other_fd=''
    for other_fd in "$REMOTE_LISTEN_FD" "${(@k)REMOTE_CONNECTION_PHASE}"; do
      [[ "$other_fd" == "$fd" ]] || _http_close_inherited_fds "$other_fd"
    done
    REMOTE_CONNECTION_PHASE=()
    zcoder_syswrite_all "$fd" "$response"
  ) </dev/null >/dev/null 2>&1 &
  pid=$!
  REMOTE_CONNECTION_WRITER[$fd]="$pid"
}

_remote_http_request_error() {
  case "$2" in
    2) _remote_http_error "$1" 413 "$REMOTE_ERROR" ;;
    3) _remote_http_error "$1" 401 "$REMOTE_ERROR" ;;
    *) _remote_http_error "$1" 400 "$REMOTE_ERROR" ;;
  esac
}

# Consume at most one chunk per ready socket per iteration. Headers and body
# retain the deadline assigned at accept; another readable byte never renews it.
_remote_server_connection_read() {
  setopt localoptions nomultibyte
  local fd="$1" chunk='' raw='' header=''
  local -i read_status=0 header_bytes=0 read_size=32768
  if [[ "${REMOTE_CONNECTION_PHASE[$fd]}" == body ]]; then
    read_size=$(( REMOTE_CONNECTION_LENGTH[$fd] - ${#REMOTE_CONNECTION_BUFFER[$fd]} ))
    (( read_size > 32768 )) && read_size=32768
  fi
  sysread -i "$fd" -s "$read_size" -t 0 chunk 2>/dev/null
  read_status=$?
  (( read_status == 4 )) && return 0
  (( read_status == 0 )) || { _remote_server_connection_close "$fd"; return; }
  REMOTE_CONNECTION_BUFFER[$fd]+="$chunk"
  if [[ "${REMOTE_CONNECTION_PHASE[$fd]}" == headers ]]; then
    raw="${REMOTE_CONNECTION_BUFFER[$fd]}"
    if [[ "$raw" != *$'\r\n\r\n'* ]]; then
      if (( ${#raw} > 65536 )); then
        _remote_http_error "$fd" 413 'request header is too large'
      fi
      return
    fi
    header="${raw%%$'\r\n\r\n'*}"
    header_bytes=$(( ${#header} + 4 ))
    _remote_http_parse_headers "$header" "Bearer ${REMOTE_TOKEN}"
    read_status=$?
    (( read_status == 0 )) || { _remote_http_request_error "$fd" "$read_status"; return; }
    REMOTE_CONNECTION_METHOD[$fd]="$REMOTE_REQUEST_METHOD"
    REMOTE_CONNECTION_TARGET[$fd]="$REMOTE_REQUEST_TARGET"
    REMOTE_CONNECTION_AUTHORIZATION[$fd]="$REMOTE_REQUEST_AUTHORIZATION"
    REMOTE_CONNECTION_LENGTH[$fd]=$REMOTE_REQUEST_LENGTH
    REMOTE_CONNECTION_BUFFER[$fd]="${raw[$(( header_bytes + 1 )),-1]}"
    REMOTE_CONNECTION_PHASE[$fd]=body
  fi
  if (( ${#REMOTE_CONNECTION_BUFFER[$fd]} >= REMOTE_CONNECTION_LENGTH[$fd] )); then
    (( EPOCHREALTIME < REMOTE_CONNECTION_DEADLINE[$fd] )) || {
      _remote_server_connection_close "$fd"; return
    }
    # Dispatch owns these globals only until this synchronous call returns.
    # Each connection carries its own parsed fields until then.
    REMOTE_REQUEST_METHOD="${REMOTE_CONNECTION_METHOD[$fd]}"
    REMOTE_REQUEST_TARGET="${REMOTE_CONNECTION_TARGET[$fd]}"
    REMOTE_REQUEST_AUTHORIZATION="${REMOTE_CONNECTION_AUTHORIZATION[$fd]}"
    REMOTE_REQUEST_LENGTH=${REMOTE_CONNECTION_LENGTH[$fd]}
    REMOTE_REQUEST_BODY="${REMOTE_CONNECTION_BUFFER[$fd][1,$REMOTE_REQUEST_LENGTH]}"
    _remote_server_dispatch_request "$fd"
    REMOTE_REQUEST_BODY=''
    [[ "${REMOTE_CONNECTION_PHASE[$fd]:-}" == writing ]] || _remote_server_connection_close "$fd"
  fi
}

_remote_server_io_poll() {
  local fd='' pid=''
  local -i accepted=0
  local -a readers=("$REMOTE_LISTEN_FD")
  local -A ready=()
  [[ -z "$REMOTE_MODEL_REQUEST_KIND" ]] || _remote_server_model_poll || true
  for fd in "${(@k)REMOTE_CONNECTION_PHASE}"; do
    pid="${REMOTE_CONNECTION_WRITER[$fd]:-}"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      unset "REMOTE_CONNECTION_WRITER[$fd]"
      _remote_server_connection_close "$fd"
    elif (( EPOCHREALTIME >= REMOTE_CONNECTION_DEADLINE[$fd] )); then
      _remote_server_connection_close "$fd"
    elif [[ "${REMOTE_CONNECTION_PHASE[$fd]}" != writing ]]; then
      readers+=("$fd")
    fi
  done
  # Wake regularly even without traffic to expire readers and reap writers.
  zselect -A ready -t 5 -r "${readers[@]}" 2>/dev/null || return 0
  if [[ -n "${ready[$REMOTE_LISTEN_FD]:-}" ]]; then
    # Bound accept work too: a connection flood must not starve existing peers.
    for (( accepted=0; accepted<4; accepted++ )); do
      ztcp -a -t "$REMOTE_LISTEN_FD" 2>/dev/null || break
      fd="$REPLY"
      if (( ${#REMOTE_CONNECTION_PHASE} >= REMOTE_SERVER_MAX_CONNECTIONS )); then
        # Sending a busy response would itself need another writer slot.
        ztcp -c "$fd" 2>/dev/null
        continue
      fi
      REMOTE_CONNECTION_PHASE[$fd]=headers
      REMOTE_CONNECTION_BUFFER[$fd]=''
      REMOTE_CONNECTION_DEADLINE[$fd]=$(( EPOCHREALTIME + REMOTE_SERVER_READ_TIMEOUT ))
    done
  fi
  for fd in "${readers[@]:1}"; do
    [[ -n "${ready[$fd]:-}" ]] || continue
    if (( EPOCHREALTIME >= REMOTE_CONNECTION_DEADLINE[$fd] )); then
      _remote_server_connection_close "$fd"
    else
      _remote_server_connection_read "$fd"
    fi
  done
}

_remote_server_handle_connection() {
  local fd="$1" read_status=0
  _remote_http_read_request "$fd" "Bearer ${REMOTE_TOKEN}"
  read_status=$?
  if (( read_status != 0 )); then
    _remote_http_request_error "$fd" "$read_status"
    return
  fi
  if [[ "$REMOTE_REQUEST_AUTHORIZATION" != "Bearer ${REMOTE_TOKEN}" ]]; then
    _remote_http_error "$fd" 401 "authentication required"
    return
  fi
  _remote_server_dispatch_request "$fd"
}

_remote_server_dispatch_request() {
  local fd="$1" target="" after="0" prompt="" turn_json="" id="" decision="" session_status=0 structured_events=0
  _remote_server_reap_worker
  target="$REMOTE_REQUEST_TARGET"
  case "$REMOTE_REQUEST_METHOD:$target" in
    POST:/v1/input) _remote_server_input_request "$fd" submit ;;
    POST:/v1/input/status|POST:/v1/input/list|POST:/v1/input/drop)
      _remote_server_input_request "$fd" "${target:t}" ;;
    GET:/v1/hello)
      _remote_server_model_ensure 1 "$fd" || true
      _remote_server_hello_json
      _remote_http_send "$fd" 200 "$REPLY"
      ;;
    GET:/v1/model)
      _remote_server_model_poll || true
      _remote_server_model_status_json
      _remote_http_send "$fd" 200 "$REPLY"
      ;;
    POST:/v1/model/ensure)
      _remote_server_model_ensure 1 "$fd" || true
      _remote_server_model_status_json
      _remote_http_send "$fd" 200 "$REPLY"
      ;;
    POST:/v1/turn)
      if [[ -f "$REMOTE_RUNTIME_DIR/active.pid" || -f "$REMOTE_RUNTIME_DIR/pending_prompt" ]]; then
        _remote_http_error "$fd" 409 "a remote turn is already running"
        return
      fi
      if ! json_parse_flat_object "$REMOTE_REQUEST_BODY"; then
        _remote_http_error "$fd" 400 "invalid turn request: ${ZJSON_ERROR:-parse error}"
        return
      fi
      prompt="${JSON_OBJECT[prompt]:-}"
      [[ -n "$prompt" && "${JSON_OBJECT_TYPES[prompt]:-}" == string ]] || {
        _remote_http_error "$fd" 400 "prompt must be a non-empty string"
        return
      }
      if (( ${+JSON_OBJECT[structured_events]} )); then
        [[ "${JSON_OBJECT_TYPES[structured_events]:-}" == true || "${JSON_OBJECT_TYPES[structured_events]:-}" == false ]] || {
          _remote_http_error "$fd" 400 "structured_events must be a boolean"
          return
        }
        [[ "${JSON_OBJECT_TYPES[structured_events]}" == true ]] && structured_events=1
      fi
      _remote_server_model_ensure 1 "$fd" || true
      if [[ "$REMOTE_MODEL_STATUS" == warming ]]; then
        if ! _remote_server_queue_turn "$prompt" "$structured_events"; then
          _remote_http_error "$fd" 500 "could not queue the remote turn during model warm-up"
          return
        fi
        zjson_quote "$REPLY"; turn_json="$REPLY"
        _remote_http_send "$fd" 202 "{\"turn_id\":${turn_json},\"model_status\":\"warming\"}"
        return
      elif [[ "$REMOTE_MODEL_STATUS" == error ]]; then
        _remote_http_error "$fd" 503 "${REMOTE_MODEL_ERROR:-model preparation failed}"
        return
      fi
      if ! _remote_server_start_turn "$prompt" "$fd" "$structured_events"; then
        _remote_http_error "$fd" 500 "could not start the remote turn"
        return
      fi
      zjson_quote "$REPLY"; turn_json="$REPLY"
      _remote_http_send "$fd" 202 "{\"turn_id\":${turn_json}}"
      ;;
    GET:/v1/events\?after=*)
      after="${target#*/v1/events\?after=}"
      [[ "$after" == <0-> ]] || { _remote_http_error "$fd" 400 "after must be a non-negative integer"; return; }
      _remote_server_progress_pending_turn "$fd" || true
      _remote_server_next_event "$after"
      _remote_server_git_json
      _remote_http_send "$fd" 200 "$REPLY"
      ;;
    GET:/v1/sessions\?after=*)
      after="${target#*/v1/sessions\?after=}"
      [[ "$after" == <0-> ]] || { _remote_http_error "$fd" 400 "after must be a non-negative integer"; return; }
      _remote_server_session_summary "$after" || true
      _remote_http_send "$fd" 200 "$REPLY"
      ;;
    GET:/v1/session\?id=*\&after=*)
      id="${target#*/v1/session\?id=}"
      after="${id#*\&after=}"
      id="${id%%\&after=*}"
      _remote_server_session_event "$id" "$after"
      session_status=$?
      if (( session_status != 0 )); then
        if (( session_status == 2 )); then
          _remote_http_error "$fd" 404 "remote session does not exist"
          return
        fi
      fi
      _remote_http_send "$fd" 200 "$REPLY"
      ;;
    POST:/v1/session/select)
      if [[ -f "$REMOTE_RUNTIME_DIR/active.pid" || -f "$REMOTE_RUNTIME_DIR/pending_prompt" ]]; then
        _remote_http_error "$fd" 409 "cannot switch sessions while a remote turn is running"
        return
      fi
      if ! json_parse_flat_object "$REMOTE_REQUEST_BODY"; then
        _remote_http_error "$fd" 400 "invalid session selection"
        return
      fi
      id="${JSON_OBJECT[id]:-}"
      if ! _remote_server_select_session "$id"; then
        _remote_http_error "$fd" 404 "remote session does not exist"
        return
      fi
      _remote_http_send "$fd" 200 '{"ok":true}'
      ;;
    POST:/v1/session/new)
      if [[ -f "$REMOTE_RUNTIME_DIR/active.pid" || -f "$REMOTE_RUNTIME_DIR/pending_prompt" ]]; then
        _remote_http_error "$fd" 409 "cannot create a session while a remote turn is running"
        return
      fi
      if ! _remote_server_new_session; then
        _remote_http_error "$fd" 500 "could not create a remote session"
        return
      fi
      zjson_quote "$REMOTE_SESSION_ID"; id="$REPLY"
      _remote_http_send "$fd" 200 "{\"id\":${id}}"
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
      if ! json_parse_flat_object "$REMOTE_REQUEST_BODY"; then
        _remote_http_error "$fd" 400 'invalid cancellation request'; return
      fi
      # Both fields are required for a scoped request. An empty legacy object
      # remains supported, but a malformed scope must never become global.
      if (( ${+JSON_OBJECT[session_id]} || ${+JSON_OBJECT[turn_id]} )); then
        if [[ ${JSON_OBJECT_TYPES[session_id]:-} != string || ${JSON_OBJECT_TYPES[turn_id]:-} != string ||
              -z ${JSON_OBJECT[session_id]} || -z ${JSON_OBJECT[turn_id]} ]]; then
          _remote_http_error "$fd" 400 'session_id and turn_id must be non-empty strings'; return
        fi
        if [[ ${JSON_OBJECT[session_id]} != "$REMOTE_SESSION_ID" || ${JSON_OBJECT[turn_id]} != "$REMOTE_TURN_ID" ]]; then
          _remote_http_error "$fd" 409 'cancellation does not match the current session and turn'; return
        fi
      elif (( ${#JSON_OBJECT} )); then
        _remote_http_error "$fd" 400 'unscoped cancellation must be an empty object'; return
      fi
      if (( ${+JSON_OBJECT[continue_queued]} )) && [[ ${JSON_OBJECT_TYPES[continue_queued]} != (true|false) ]]; then
        _remote_http_error "$fd" 400 'continue_queued must be a boolean'; return
      fi
      local -i REMOTE_CANCEL_CONTINUED=0
      if _remote_server_cancel_turn "${JSON_OBJECT[continue_queued]:-false}" "$fd"; then
        if (( REMOTE_CANCEL_CONTINUED )); then _remote_http_send "$fd" 200 '{"ok":true,"continued":true}'
        else _remote_http_send "$fd" 200 '{"ok":true}'
        fi
      else
        _remote_http_error "$fd" 409 "no remote turn is running"
      fi
      ;;
    *) _remote_http_error "$fd" 404 "unknown endpoint" ;;
  esac
}

remote_server_stop() {
  local pid="" owner_pid="" fd=""
  local -i owns_runtime=1
  if [[ -n "$REMOTE_MODEL_REQUEST_KIND" ]]; then
    http_async_cancel
    REMOTE_MODEL_REQUEST_KIND=''
  fi
  for fd in "${(@k)REMOTE_CONNECTION_PHASE}"; do
    _remote_server_connection_close "$fd"
  done
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
        "$REMOTE_RUNTIME_DIR/pending_structured_events" "$REMOTE_RUNTIME_DIR/server.pid" 2>/dev/null
    fi
  fi
  if [[ -n "$REMOTE_LISTEN_FD" ]]; then
    ztcp -c "$REMOTE_LISTEN_FD" 2>/dev/null
    REMOTE_LISTEN_FD=""
  fi
}

# Older servers kept conversations beneath their named runtime directory.
# Publish aliases in the shared store: existing IDs, selected-session markers,
# and writer locks keep referring to the same data without copying histories.
_remote_server_share_legacy_sessions() {
  emulate -L zsh
  local legacy_root="${REMOTE_RUNTIME_DIR:A}/sessions" legacy='' shared='' id=''
  [[ ${legacy_root:A} != ${ZCODER_SESSIONS_DIR:A} ]] || return 0
  for legacy in "$legacy_root"/*.session(N/); do
    id=${legacy:t:r}
    _state_valid_id "$id" || continue
    shared="$ZCODER_SESSIONS_DIR/$id.session"
    [[ ${shared:A} == ${legacy:A} ]] && continue
    if [[ -e $shared || -h $shared ]]; then
      REMOTE_ERROR="session ID conflict while sharing legacy session: $id"
      return 1
    fi
    # Use the parent directory as destination so an existing same-name
    # directory is rejected rather than receiving a nested link.
    if ! zf_ln -s "${legacy:A}" "$ZCODER_SESSIONS_DIR"; then
      [[ ${shared:A} == ${legacy:A} ]] && continue
      REMOTE_ERROR="could not share legacy session: $id"
      return 1
    fi
  done
  return 0
}

remote_server_main() {
  local safe_name="" existing_pid="" selected_session="" old_umask="$(umask)"
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
  # TUI and API sessions share storage; workspace/profile filtering remains
  # authoritative for listings, selection, transcript reads and worker loads.
  if ! state_init storage || ! _remote_server_share_legacy_sessions; then
    print -u2 -r -- "Error: ${REMOTE_ERROR:-could not initialize shared session storage}"
    return 1
  fi
  if ! state_init resume; then
    print -u2 -- "Error: could not initialize remote session storage"
    return 1
  fi
  REMOTE_SESSION_ID="$CURRENT_SESSION_ID"
  selected_session="${mapfile[$REMOTE_RUNTIME_DIR/selected_session]:-}"
  if _remote_server_select_session "$selected_session"; then
    REMOTE_SESSION_ID="$selected_session"
  else
    mapfile[$REMOTE_RUNTIME_DIR/selected_session]="$REMOTE_SESSION_ID" || true
  fi
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
  {
    while (( RUNNING )); do
      _remote_server_io_poll
    done
  } always {
    remote_server_stop
  }
}

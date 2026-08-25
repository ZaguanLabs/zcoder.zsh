# Native HTTP/1.1 client for a local or LAN Ollama server.

typeset -g OLLAMA_HOST="${OLLAMA_HOST:-localhost:11434}"
typeset -g HTTP_BODY=""
typeset -g HTTP_ERROR=""
typeset -g HTTP_NET_HOST=""
typeset -g HTTP_NET_PORT="11434"
typeset -g HTTP_ACTIVE_FD=""
typeset -g HTTP_ASYNC_PID=""
typeset -g HTTP_ASYNC_BASE=""
typeset -gi OLLAMA_RUNNING_CONTEXT=0
typeset -ga OLLAMA_MODELS=()

ollama_normalize_host() {
  local endpoint="$1"
  HTTP_ERROR=""
  endpoint="${endpoint##[[:space:]]#}"
  endpoint="${endpoint%%[[:space:]]#}"
  if [[ "$endpoint" == https://* ]]; then
    HTTP_ERROR="HTTPS is not supported by the native Zsh TCP transport"
    return 1
  fi
  endpoint="${endpoint#http://}"
  endpoint="${endpoint%/}"
  if [[ -z "$endpoint" || "$endpoint" == */* || "$endpoint" == *[[:space:]]* ]]; then
    HTTP_ERROR="expected hostname:port or http://hostname:port"
    return 1
  fi
  if [[ "$endpoint" == \[*\] ]]; then
    endpoint+=":11434"
  elif [[ "$endpoint" == \[*\]:<-> || "$endpoint" == *:<-> ]]; then
    :
  elif [[ "$endpoint" == *:* ]]; then
    HTTP_ERROR="IPv6 addresses must be enclosed in brackets"
    return 1
  else
    endpoint+=":11434"
  fi
  REPLY="$endpoint"
}

_http_split_host() {
  local endpoint="${1#http://}"
  endpoint="${endpoint%%/*}"
  if [[ "$endpoint" == \[*\]:<-> ]]; then
    HTTP_NET_HOST="${endpoint#\[}"
    HTTP_NET_HOST="${HTTP_NET_HOST%%\]*}"
    HTTP_NET_PORT="${endpoint##*:}"
  else
    HTTP_NET_HOST="${endpoint%:*}"
    HTTP_NET_PORT="${endpoint##*:}"
  fi
}

_http_byte_length() {
  setopt localoptions nomultibyte
  REPLY=${#1}
}

_http_dechunk() {
  setopt localoptions extendedglob nomultibyte
  local wire="$1" output="" size_line="" hex="" data=""
  local -i size
  while [[ -n "$wire" ]]; do
    [[ "$wire" == *$'\r\n'* ]] || { HTTP_ERROR="incomplete chunk header"; return 1; }
    size_line="${wire%%$'\r\n'*}"
    wire="${wire[$(( ${#size_line} + 3 )),-1]}"
    hex="${size_line%%;*}"
    [[ "$hex" == [[:xdigit:]]## ]] || { HTTP_ERROR="invalid chunk size"; return 1; }
    size=$(( 16#$hex ))
    (( size == 0 )) && break
    (( ${#wire} >= size + 2 )) || { HTTP_ERROR="incomplete HTTP chunk"; return 1; }
    data="${wire[1,$size]}"
    output+="$data"
    wire="${wire[$(( size + 3 )),-1]}"
  done
  REPLY="$output"
}

_http_close_active() {
  [[ -n "$HTTP_ACTIVE_FD" ]] || return 0
  ztcp -c "$HTTP_ACTIVE_FD" 2>/dev/null
  HTTP_ACTIVE_FD=""
}

http_request() {
  setopt localoptions nomultibyte
  local method="$1" endpoint_path="$2" payload="${3:-}" endpoint="${4:-$OLLAMA_HOST}"
  local extra_headers="${5:-}" fd="" request="" chunk="" raw="" header="" body="" status_line=""
  local -i payload_bytes
  HTTP_BODY=""
  HTTP_ERROR=""

  _http_split_host "$endpoint"
  if ! ztcp "$HTTP_NET_HOST" "$HTTP_NET_PORT" 2>/dev/null; then
    HTTP_ERROR="cannot connect to Ollama at $endpoint"
    return 1
  fi
  fd=$REPLY
  HTTP_ACTIVE_FD="$fd"
  _http_byte_length "$payload"; payload_bytes=$REPLY
  [[ -z "$extra_headers" || "$extra_headers" == *$'\r\n' ]] || extra_headers+=$'\r\n'
  if [[ "$extra_headers" == *$'\r\n\r\n'* ]]; then
    HTTP_ERROR="invalid extra HTTP headers"
    _http_close_active
    return 1
  fi
  request="${method} ${endpoint_path} HTTP/1.1"$'\r\n'"Host: ${endpoint}"$'\r\n'\
"Content-Type: application/json"$'\r\n'"Accept: application/json"$'\r\n'\
"${extra_headers}""Connection: close"$'\r\n'"Content-Length: ${payload_bytes}"$'\r\n\r\n'"${payload}"

  if ! syswrite -o "$fd" "$request" 2>/dev/null; then
    HTTP_ERROR="failed to send request to Ollama"
    _http_close_active
    return 1
  fi
  while sysread -i "$fd" -s 32768 -t 300 chunk 2>/dev/null; do
    raw+="$chunk"
  done
  _http_close_active

  [[ "$raw" == *$'\r\n\r\n'* ]] || { HTTP_ERROR="Ollama returned an incomplete HTTP response"; return 1; }
  header="${raw%%$'\r\n\r\n'*}"
  body="${raw[$(( ${#header} + 5 )),-1]}"
  status_line="${header%%$'\r\n'*}"
  if [[ "$status_line" != 'HTTP/'*' 2'* ]]; then
    HTTP_ERROR="Ollama HTTP error: $status_line"
    HTTP_BODY="$body"
    return 1
  fi
  if [[ "${(L)header}" == *$'transfer-encoding: chunked'* ]]; then
    _http_dechunk "$body" || return 1
    HTTP_BODY="$REPLY"
  else
    HTTP_BODY="$body"
  fi
}

http_async_cleanup() {
  local base="${1:-$HTTP_ASYNC_BASE}"
  [[ -n "$base" ]] && zf_rm -f -- "${base}.body" "${base}.error" \
    "${base}.status" "${base}.done" 2>/dev/null
  if [[ -z "$1" || "$base" == "$HTTP_ASYNC_BASE" ]]; then
    HTTP_ASYNC_PID=""
    HTTP_ASYNC_BASE=""
  fi
}

_http_close_inherited_fds() {
  local fd=""
  for fd in "$@"; do
    [[ "$fd" == <0-> ]] || continue
    ztcp -c "$fd" 2>/dev/null || true
  done
}

# Run one HTTP request in a child process so the curses loop can keep polling.
# The child owns the TCP descriptor; terminating it closes the connection and
# propagates cancellation through Ollama's HTTP request context.
http_async_start() {
  local method="$1" endpoint_path="$2" payload="${3:-}" endpoint="${4:-$OLLAMA_HOST}"
  local tmp_root="${TMPDIR:-/tmp}"
  local base="${tmp_root%/}/zcoder_http_${$}_${EPOCHREALTIME//./_}_${RANDOM}"
  shift 4
  local -a inherited_fds=("$@")

  HTTP_ERROR=""
  if [[ -n "$HTTP_ASYNC_PID" ]] && kill -0 "$HTTP_ASYNC_PID" 2>/dev/null; then
    HTTP_ERROR="an Ollama request is already running"
    return 1
  fi
  http_async_cleanup
  HTTP_ASYNC_BASE="$base"
  zcoder_debug http_async_start "method=$method path=${(qqq)endpoint_path} endpoint=${(qqq)endpoint}"

  (
    trap - EXIT
    trap '_http_close_active; exit 130' INT TERM HUP
    local -i request_status=0
    _http_close_inherited_fds "${inherited_fds[@]}"
    HTTP_BODY=""
    HTTP_ERROR=""
    http_request "$method" "$endpoint_path" "$payload" "$endpoint" || request_status=$?
    mapfile[${base}.body]="$HTTP_BODY"
    mapfile[${base}.error]="$HTTP_ERROR"
    mapfile[${base}.status]="$request_status"
    mapfile[${base}.done]="done"
    exit "$request_status"
  ) </dev/null >/dev/null 2>&1 &
  HTTP_ASYNC_PID=$!
  zcoder_debug http_async_started "pid=$HTTP_ASYNC_PID base=${(qqq)base}"
}

http_async_ready() {
  [[ -n "$HTTP_ASYNC_BASE" && -f "${HTTP_ASYNC_BASE}.done" ]] && return 0
  [[ -n "$HTTP_ASYNC_PID" ]] && kill -0 "$HTTP_ASYNC_PID" 2>/dev/null && return 1
  return 0
}

http_async_collect() {
  local pid="$HTTP_ASYNC_PID" base="$HTTP_ASYNC_BASE" request_status="1"
  HTTP_BODY=""
  HTTP_ERROR=""
  [[ -n "$base" ]] || { HTTP_ERROR="no Ollama request is running"; return 1; }

  if [[ -f "${base}.done" ]]; then
    HTTP_BODY="${mapfile[${base}.body]-}"
    HTTP_ERROR="${mapfile[${base}.error]-}"
    request_status="${mapfile[${base}.status]-1}"
  else
    HTTP_ERROR="Ollama request worker exited before returning a result"
  fi
  [[ -n "$pid" ]] && wait "$pid" 2>/dev/null
  zcoder_debug http_async_collect "pid=${pid:-none} status=$request_status body_chars=${#HTTP_BODY} error=${(qqq)HTTP_ERROR}"
  http_async_cleanup "$base"
  [[ "$request_status" == <0-255> ]] || request_status=1
  return "$request_status"
}

http_async_cancel() {
  local reason="${1:-cancelled}" pid="$HTTP_ASYNC_PID" base="$HTTP_ASYNC_BASE"
  [[ -n "$pid" || -n "$base" ]] && zcoder_debug http_async_cancel "pid=${pid:-none} reason=${(qqq)reason} base=${(qqq)base}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    zselect -t 2 2>/dev/null
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  http_async_cleanup "$base"
  HTTP_BODY=""
  HTTP_ERROR="Ollama request cancelled: ${reason}"
}

ollama_chat() {
  http_request POST /api/chat "$1" "${2:-$OLLAMA_HOST}"
}

ollama_get_models() {
  local host="${1:-$OLLAMA_HOST}"
  OLLAMA_MODELS=()
  http_request GET /api/tags "" "$host" || return 1
  if ! json_parse_models "$HTTP_BODY"; then
    HTTP_ERROR="could not parse Ollama model list: ${JSON_ERROR:-invalid JSON}"
    return 1
  fi
  OLLAMA_MODELS=("${JSON_MODEL_NAMES[@]}")
}

ollama_get_running_context() {
  local model="$1" host="${2:-$OLLAMA_HOST}"
  OLLAMA_RUNNING_CONTEXT=0
  http_request GET /api/ps "" "$host" || return 1
  if ! json_parse_running_model_context "$HTTP_BODY" "$model"; then
    HTTP_ERROR="could not parse Ollama running-model list: ${JSON_ERROR:-invalid JSON}"
    return 1
  fi
  OLLAMA_RUNNING_CONTEXT="$JSON_RUNNING_MODEL_CONTEXT"
  (( OLLAMA_RUNNING_CONTEXT > 0 ))
}

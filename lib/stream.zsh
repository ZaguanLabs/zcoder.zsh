# Incremental HTTP framing and Ollama NDJSON. Only the parent updates the TUI;
# the existing request worker appends decoded bytes to private request storage.
typeset -g HTTP_STREAM_WIRE="" HTTP_STREAM_STATE=headers HTTP_STREAM_OUTPUT=""
typeset -gi HTTP_STREAM_LEFT=0 HTTP_STREAM_BYTES=0
typeset -g AGENT_STREAM_BUFFER="" AGENT_STREAM_CONTENT="" AGENT_STREAM_THINKING="" AGENT_STREAM_CALLS=""
typeset -g AGENT_STREAM_ERROR="" AGENT_STREAM_BASE=""
typeset -gi AGENT_STREAM_DONE=0 AGENT_STREAM_EOF=0 AGENT_STREAM_RECORDS=0
typeset -gi AGENT_STREAM_PROMPT_TOKENS=0 AGENT_STREAM_OUTPUT_TOKENS=0 AGENT_STREAM_PREVIEW=0
typeset -gi AGENT_STREAM_CONTEXT_BASE=0 AGENT_STREAM_CONTEXT_BYTES=0

http_stream_reset() {
  HTTP_STREAM_WIRE=""; HTTP_STREAM_STATE=headers; HTTP_STREAM_OUTPUT=""
  HTTP_STREAM_LEFT=0; HTTP_STREAM_BYTES=0
}

http_stream_feed() {
  emulate -L zsh
  setopt extendedglob nomultibyte
  local header="" line="" key="" value="" length="" encoding="" part=""
  local -i take=0
  HTTP_STREAM_OUTPUT=""
  HTTP_STREAM_WIRE+="$1"
  while true; do
    case "$HTTP_STREAM_STATE" in
      headers)
        if [[ "$HTTP_STREAM_WIRE" != *$'\r\n\r\n'* ]]; then
          (( ${#HTTP_STREAM_WIRE} <= 65536 )) || { HTTP_ERROR="Ollama response headers exceed 64 KiB"; return 1; }
          return 0
        fi
        header="${HTTP_STREAM_WIRE%%$'\r\n\r\n'*}"
        (( ${#header} <= 65536 )) || { HTTP_ERROR="Ollama response headers exceed 64 KiB"; return 1; }
        HTTP_STREAM_WIRE="${HTTP_STREAM_WIRE[$(( ${#header}+5 )),-1]}"
        line="${header%%$'\r\n'*}"
        [[ "$line" == HTTP/1.[01]' 200 '* ]] || { HTTP_ERROR="Ollama HTTP error: $line"; return 1; }
        for line in "${(@f)${header//$'\r'/}}"; do
          [[ "$line" == *:* ]] || continue
          key="${(L)${line%%:*}}"; value="${line#*:}"
          value="${value##[[:space:]]#}"; value="${value%%[[:space:]]#}"
          case "$key" in
            content-length)
              [[ "$value" == <0-> && ${#value} -le 8 && -z "$length" ]] || { HTTP_ERROR="invalid streaming Content-Length"; return 1; }
              length="$value" ;;
            transfer-encoding) encoding="${value:l}" ;;
          esac
        done
        if [[ "$encoding" == chunked && -z "$length" ]]; then HTTP_STREAM_STATE=size
        elif [[ -n "$encoding" ]]; then HTTP_ERROR="unsupported streaming HTTP transfer framing"; return 1
        elif [[ -n "$length" ]]; then HTTP_STREAM_STATE=length; HTTP_STREAM_LEFT=$(( 10#$length ))
        else HTTP_STREAM_STATE=close
        fi
        ;;
      size)
        if [[ "$HTTP_STREAM_WIRE" != *$'\r\n'* ]]; then
          (( ${#HTTP_STREAM_WIRE} <= 1024 )) || { HTTP_ERROR="invalid streaming chunk header"; return 1; }
          return 0
        fi
        line="${HTTP_STREAM_WIRE%%$'\r\n'*}"
        (( ${#line} <= 1024 )) || { HTTP_ERROR="invalid streaming chunk header"; return 1; }
        HTTP_STREAM_WIRE="${HTTP_STREAM_WIRE[$(( ${#line}+3 )),-1]}"
        value="${line%%;*}"
        [[ "$value" == [[:xdigit:]]## && ${#value} -le 8 ]] || { HTTP_ERROR="invalid streaming chunk size"; return 1; }
        HTTP_STREAM_LEFT=$(( 16#$value ))
        (( HTTP_STREAM_LEFT <= 67108864 )) || { HTTP_ERROR="streaming chunk exceeds 64 MiB"; return 1; }
        (( HTTP_STREAM_LEFT )) && HTTP_STREAM_STATE=chunk || HTTP_STREAM_STATE=trailers
        ;;
      length|chunk|close)
        if [[ "$HTTP_STREAM_STATE" != close ]] && (( HTTP_STREAM_LEFT == 0 )); then
          [[ "$HTTP_STREAM_STATE" == length ]] && HTTP_STREAM_STATE=done || HTTP_STREAM_STATE=crlf
          continue
        fi
        take=${#HTTP_STREAM_WIRE}
        (( take > 0 )) || return 0
        [[ "$HTTP_STREAM_STATE" != close ]] && (( take > HTTP_STREAM_LEFT )) && take=$HTTP_STREAM_LEFT
        (( HTTP_STREAM_BYTES+=take ))
        (( HTTP_STREAM_BYTES <= 67108864 )) || { HTTP_ERROR="Ollama stream exceeds 64 MiB"; return 1; }
        HTTP_STREAM_OUTPUT+="${HTTP_STREAM_WIRE[1,take]}"
        HTTP_STREAM_WIRE="${HTTP_STREAM_WIRE[$(( take+1 )),-1]}"
        [[ "$HTTP_STREAM_STATE" == close ]] || (( HTTP_STREAM_LEFT-=take ))
        ;;
      crlf)
        (( ${#HTTP_STREAM_WIRE} >= 2 )) || return 0
        [[ "${HTTP_STREAM_WIRE[1,2]}" == $'\r\n' ]] || { HTTP_ERROR="invalid streaming chunk terminator"; return 1; }
        HTTP_STREAM_WIRE="${HTTP_STREAM_WIRE[3,-1]}"; HTTP_STREAM_STATE=size
        ;;
      trailers)
        (( ${#HTTP_STREAM_WIRE} <= 65536 )) || { HTTP_ERROR="streaming trailers exceed 64 KiB"; return 1; }
        if [[ "$HTTP_STREAM_WIRE" == $'\r\n'* ]]; then
          HTTP_STREAM_WIRE="${HTTP_STREAM_WIRE[3,-1]}"; HTTP_STREAM_STATE=done
        elif [[ "$HTTP_STREAM_WIRE" == *$'\r\n\r\n'* ]]; then
          HTTP_STREAM_WIRE="${HTTP_STREAM_WIRE#*$'\r\n\r\n'}"; HTTP_STREAM_STATE=done
        else
          return 0
        fi
        ;;
      done)
        [[ -z "$HTTP_STREAM_WIRE" ]] || { HTTP_ERROR="unexpected bytes after streaming HTTP body"; return 1; }
        return 0 ;;
    esac
  done
}

http_stream_finish() {
  [[ "$HTTP_STREAM_STATE" == done || "$HTTP_STREAM_STATE" == close ]] && return 0
  HTTP_ERROR="Ollama closed an incomplete streaming HTTP response"
  return 1
}

http_stream_request() {
  emulate -L zsh
  setopt nomultibyte
  local method="$1" endpoint_path="$2" payload="$3" endpoint="$4" output_fd="$5"
  local fd="" request="" chunk=""
  local -i read_status=0
  HTTP_BODY=""; HTTP_ERROR=""
  http_stream_reset
  _http_split_host "$endpoint"
  ztcp "$HTTP_NET_HOST" "$HTTP_NET_PORT" 2>/dev/null || { HTTP_ERROR="cannot connect to Ollama at $endpoint"; return 1; }
  fd=$REPLY; HTTP_ACTIVE_FD="$fd"
  request="${method} ${endpoint_path} HTTP/1.1"$'\r\n'"Host: ${endpoint}"$'\r\n'\
"Content-Type: application/json"$'\r\n'"Accept: application/x-ndjson"$'\r\n'\
"Connection: close"$'\r\n'"Content-Length: ${#payload}"$'\r\n\r\n'"${payload}"
  {
    zcoder_syswrite_all "$fd" "$request" || { HTTP_ERROR="failed to send request to Ollama"; return 1; }
    while [[ "$HTTP_STREAM_STATE" != done ]]; do
      chunk=""
      sysread -i "$fd" -s 32768 -t "$HTTP_READ_TIMEOUT" chunk 2>/dev/null
      read_status=$?
      if (( read_status != 0 )); then
        (( read_status == 5 )) && break
        HTTP_ERROR="failed reading Ollama stream (read status ${read_status}; timeout ${HTTP_READ_TIMEOUT}s)"
        return 1
      fi
      http_stream_feed "$chunk" || return 1
      if [[ -n "$HTTP_STREAM_OUTPUT" ]]; then
        zcoder_syswrite_all "$output_fd" "$HTTP_STREAM_OUTPUT" || { HTTP_ERROR="could not publish Ollama stream bytes"; return 1; }
      fi
    done
    http_stream_finish
  } always { _http_close_active; }
}

http_async_stream_start() {
  local -i HTTP_STREAM_REQUEST=1
  http_async_start "$@"
}

agent_stream_reset() {
  AGENT_STREAM_BUFFER=""; AGENT_STREAM_CONTENT=""; AGENT_STREAM_THINKING=""; AGENT_STREAM_CALLS=""
  AGENT_STREAM_ERROR=""; AGENT_STREAM_BASE="$HTTP_ASYNC_BASE"
  AGENT_STREAM_DONE=0; AGENT_STREAM_EOF=0; AGENT_STREAM_RECORDS=0
  AGENT_STREAM_PROMPT_TOKENS=0; AGENT_STREAM_OUTPUT_TOKENS=0
  AGENT_STREAM_PREVIEW=0
  AGENT_STREAM_CONTEXT_BASE=${AGENT_ESTIMATED_TOKENS:-0}
  AGENT_STREAM_CONTEXT_BYTES=0
}

agent_stream_record() {
  emulate -L zsh
  local -i JSON_REQUIRE_COMPLETE_TOOLS=1
  local record="$1" calls="" name=""
  [[ -n "${record//[[:space:]]/}" ]] || return 0
  (( ! AGENT_STREAM_DONE )) || { AGENT_STREAM_ERROR="data after Ollama's final stream record"; return 1; }
  if ! json_parse_ollama_response "$record"; then
    AGENT_STREAM_ERROR="invalid Ollama stream JSON: ${ZJSON_ERROR:-malformed record}"; return 1
  fi
  [[ -z "$JSON_RESPONSE_ERROR" ]] || { AGENT_STREAM_ERROR="$JSON_RESPONSE_ERROR"; return 1; }
  (( JSON_RESPONSE_DONE >= 0 )) || { AGENT_STREAM_ERROR="Ollama stream record lacks a boolean done field"; return 1; }
  for name in "${JSON_TOOL_NAMES[@]}"; do
    [[ -n "$name" ]] || { AGENT_STREAM_ERROR="Ollama stream tool call lacks a function name"; return 1; }
  done
  AGENT_STREAM_CONTENT+="$JSON_RESPONSE_CONTENT"
  AGENT_STREAM_THINKING+="$JSON_RESPONSE_THINKING"
  calls="${JSON_RESPONSE_TOOL_CALLS[2,-2]}"
  [[ -n "$calls" ]] && AGENT_STREAM_CALLS+="${AGENT_STREAM_CALLS:+,}${calls}"
  if (( ${UI_ACTIVE:-0} && $+functions[agent_context_component_byte_tokens] )); then
    # Count only new bytes; never serialize the growing conversation per token.
    _http_byte_length "${JSON_RESPONSE_CONTENT}${JSON_RESPONSE_THINKING}${calls}"
    (( AGENT_STREAM_CONTEXT_BYTES += REPLY ))
    agent_context_component_byte_tokens "$AGENT_STREAM_CONTEXT_BYTES"
    AGENT_ESTIMATED_TOKENS=$(( AGENT_STREAM_CONTEXT_BASE + REPLY ))
  fi
  (( AGENT_STREAM_RECORDS++ ))
  if (( JSON_RESPONSE_DONE == 1 )); then
    AGENT_STREAM_DONE=1
    AGENT_STREAM_PROMPT_TOKENS=$JSON_RESPONSE_PROMPT_TOKENS
    AGENT_STREAM_OUTPUT_TOKENS=$JSON_RESPONSE_OUTPUT_TOKENS
  fi
  return 0
}

# Each poll processes a bounded number of records and reads at most 32 KiB.
# Incomplete UTF-8 and JSON remain buffered until their newline arrives.
agent_stream_drain() {
  emulate -L zsh
  local chunk="" record=""
  local -i read_status=0 count=0
  [[ -n "$AGENT_STREAM_BASE" && "$AGENT_STREAM_BASE" == "$HTTP_ASYNC_BASE" && -n "$HTTP_ASYNC_STREAM_FD" ]] || {
    AGENT_STREAM_ERROR="stale Ollama stream request"; return 1
  }
  if [[ "$AGENT_STREAM_BUFFER" != *$'\n'* ]]; then
    sysread -i "$HTTP_ASYNC_STREAM_FD" -s 32768 chunk 2>/dev/null
    read_status=$?
    if (( read_status == 0 )); then
      AGENT_STREAM_BUFFER+="$chunk"; AGENT_STREAM_EOF=0
    elif (( read_status == 5 )); then AGENT_STREAM_EOF=1
    else AGENT_STREAM_ERROR="could not read Ollama stream spool"; return 1
    fi
  fi
  while [[ "$AGENT_STREAM_BUFFER" == *$'\n'* ]] && (( count < 64 )); do
    record="${AGENT_STREAM_BUFFER%%$'\n'*}"
    AGENT_STREAM_BUFFER="${AGENT_STREAM_BUFFER#*$'\n'}"
    agent_stream_record "$record" || return 1
    (( count++ ))
  done
  (( ${#AGENT_STREAM_BUFFER} <= 8388608 )) || { AGENT_STREAM_ERROR="Ollama stream record exceeds 8 MiB"; return 1; }
  return 0
}

agent_stream_preview() {
  (( ${UI_ACTIVE:-0} )) || return 0
  [[ -n "$AGENT_STREAM_CONTENT" || -n "$AGENT_STREAM_THINKING" ]] || return 0
  if (( AGENT_STREAM_PREVIEW == 0 )); then
    ui_append_message assistant "$AGENT_STREAM_CONTENT" "$AGENT_STREAM_THINKING"
    AGENT_STREAM_PREVIEW=${#UI_ROLES}; UI_STREAM_INDEX=$AGENT_STREAM_PREVIEW
  elif [[ "${UI_CONTENTS[AGENT_STREAM_PREVIEW]}" != "$AGENT_STREAM_CONTENT" || "${UI_THINKINGS[AGENT_STREAM_PREVIEW]}" != "$AGENT_STREAM_THINKING" ]]; then
    UI_CONTENTS[AGENT_STREAM_PREVIEW]="$AGENT_STREAM_CONTENT"
    UI_THINKINGS[AGENT_STREAM_PREVIEW]="$AGENT_STREAM_THINKING"
    transcript_changed "$AGENT_STREAM_PREVIEW"
  fi
  ui_draw_chat
}

agent_stream_ready() {
  local -i ready=0
  # Observe completion before reading: bytes and the done marker may otherwise
  # appear between a temporary spool EOF and the worker readiness check.
  http_async_ready && ready=1
  agent_stream_drain || return 0
  agent_stream_preview
  (( ready )) || return 1
  (( AGENT_STREAM_EOF )) || return 1
  # Let collection report a transport error or a worker crash accurately.
  [[ -f "${HTTP_ASYNC_BASE}.done" && "${mapfile[${HTTP_ASYNC_BASE}.status]:-1}" == 0 ]] || return 0
  if [[ -n "${AGENT_STREAM_BUFFER//[[:space:]]/}" ]]; then
    agent_stream_record "$AGENT_STREAM_BUFFER" || return 0
    AGENT_STREAM_BUFFER=""
  fi
  (( AGENT_STREAM_DONE )) || AGENT_STREAM_ERROR="Ollama stream ended before done:true"
  return 0
}

agent_stream_response() {
  local content="" thinking=""
  zjson_quote "$AGENT_STREAM_CONTENT"; content="$REPLY"
  zjson_quote "$AGENT_STREAM_THINKING"; thinking="$REPLY"
  REPLY="{\"message\":{\"role\":\"assistant\",\"content\":${content},\"thinking\":${thinking},\"tool_calls\":[${AGENT_STREAM_CALLS}]},\"done\":true,\"prompt_eval_count\":${AGENT_STREAM_PROMPT_TOKENS},\"eval_count\":${AGENT_STREAM_OUTPUT_TOKENS}}"
}

agent_stream_commit() {
  (( AGENT_STREAM_PREVIEW > 0 && AGENT_STREAM_PREVIEW == UI_STREAM_INDEX )) || return 1
  UI_CONTENTS[AGENT_STREAM_PREVIEW]="$1"; UI_THINKINGS[AGENT_STREAM_PREVIEW]="${2:-}"
  transcript_changed "$AGENT_STREAM_PREVIEW"
  UI_STREAM_INDEX=0; AGENT_STREAM_PREVIEW=0
}

agent_stream_interrupt() {
  (( AGENT_STREAM_PREVIEW > 0 && AGENT_STREAM_PREVIEW == UI_STREAM_INDEX )) || return 0
  AGENT_ESTIMATED_TOKENS=$AGENT_STREAM_CONTEXT_BASE
  agent_stream_commit "${UI_CONTENTS[AGENT_STREAM_PREVIEW]}"$'\n\n'"[${1:-Interrupted response; partial text only.}]" "${UI_THINKINGS[AGENT_STREAM_PREVIEW]}"
  ui_draw_chat
}

agent_stream_chat() {
  local payload="$1" host="$2" saved_error=""
  local -i wait_status=0 request_status=0
  agent_stream_interrupt "Response was not accepted; partial text only."
  http_async_stream_start POST /api/chat "$payload" "$host" || return 1
  agent_stream_reset
  ui_wait_for_generation
  wait_status=$?
  if (( wait_status != 0 )) || [[ -n "$AGENT_STREAM_ERROR" ]]; then
    AGENT_ESTIMATED_TOKENS=$AGENT_STREAM_CONTEXT_BASE
    saved_error="$AGENT_STREAM_ERROR"
    http_async_cancel "${saved_error:-Escape pressed}"
    (( wait_status == 130 )) && AGENT_CANCELLED=1
    [[ -n "$saved_error" ]] && HTTP_ERROR="$saved_error"
    agent_stream_interrupt
    (( wait_status != 0 )) && return "$wait_status"
    return 1
  fi
  http_async_collect
  request_status=$?
  if (( request_status != 0 )); then
    AGENT_ESTIMATED_TOKENS=$AGENT_STREAM_CONTEXT_BASE
    (( AGENT_STREAM_RECORDS > 0 )) && HTTP_ERROR="Interrupted Ollama stream: ${HTTP_ERROR}"
    agent_stream_interrupt
    return "$request_status"
  fi
  agent_stream_response; HTTP_BODY="$REPLY"
  return 0
}

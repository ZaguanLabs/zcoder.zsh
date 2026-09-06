#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect zsh/net/tcp || exit 1
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json mcp http instructions skills transcript tools compact goal agent state input terminal ui overlays stream; do
  source "$fixture_root/lib/${fixture_lib}.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_WORKSPACE="${fixture_base:h}" ZCODER_TOOL_EXPOSURE=full ZCODER_COMMAND_POLICY=deny ZCODER_STREAM=true
typeset -gi STATE_ENABLED=0 AGENT_REQUIRE_FINISH_TOOL=0 AGENT_TRANSPORT_RETRY_LIMIT=0
typeset -g fixture_listener="" fixture_server_pid=""
typeset -gi fixture_port=0 fixture_attempt=0
for fixture_attempt in {1..20}; do
  fixture_port=$(( 20000 + RANDOM ))
  if ztcp -l "$fixture_port" 2>/dev/null; then fixture_listener=$REPLY; break; fi
done
[[ -n "$fixture_listener" ]] || exit 1
OLLAMA_HOST="127.0.0.1:${fixture_port}"
HTTP_READ_TIMEOUT=5
fixture_read_request() {
  local fd="$1" wire="" chunk="" header="" line="" length=0 body=""
  while true; do
    sysread -i "$fd" -s 32768 -t 5 chunk 2>/dev/null || return 1
    wire+="$chunk"
    [[ "$wire" == *$'\r\n\r\n'* ]] || continue
    header="${wire%%$'\r\n\r\n'*}"; body="${wire#*$'\r\n\r\n'}"
    for line in "${(@f)${header//$'\r'/}}"; do
      [[ "$line" == 'Content-Length: '* ]] && length="${line#*: }"
    done
    (( ${#body} >= length )) && { REPLY="$body"; return 0; }
  done
}
fixture_chunk() {
  local size=""
  _http_byte_length "$2"
  printf -v size '%x' "$REPLY"
  zcoder_syswrite_all "$1" "${size}"$'\r\n'"$2"$'\r\n'
}
fixture_barrier() {
  local -F deadline=$(( EPOCHREALTIME + 15 ))
  while [[ "${mapfile[$1]:-}" != 1 ]]; do
    (( EPOCHREALTIME < deadline )) || return 1
    zselect -t 1 2>/dev/null
  done
  return 0
}
(
  trap - EXIT INT TERM
  local peer="" record="" request="" chunk="" command_json=""
  json_quote "print executed > ${fixture_base}.executed"; command_json="$REPLY"
  for phase in first final cancel truncated; do
    ztcp -a "$fixture_listener" || exit 1
    peer=$REPLY
    fixture_read_request "$peer" || exit 1
    request="$REPLY"; mapfile[${fixture_base}.request_${phase}]="$request"
    if [[ "$phase" == final ]]; then
      record='{"message":{"content":"Denied command handled."},"done":true,"prompt_eval_count":70,"eval_count":8}'
      zcoder_syswrite_all "$peer" $'HTTP/1.1 200 OK\r\nContent-Length: '"${#record}"$'\r\n\r\n'"$record"
    else
      zcoder_syswrite_all "$peer" $'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
      if [[ "$phase" == first ]]; then
        # Split the UTF-8 character across HTTP chunks and socket writes.
        fixture_chunk "$peer" $'{"message":{"content":"Hello \xe4'
        fixture_chunk "$peer" $'\xb8\x96界","thinking":"Inspect first"},"done":false}\n'
        fixture_chunk "$peer" '{"message":{"tool_calls":[{"function":{"name":"run_command","arguments":{"command":'"${command_json}"'}}}]},"done":false}'$'\n'
        fixture_barrier "${fixture_base}.release" || exit 1
        fixture_chunk "$peer" '{"done":true,"prompt_eval_count":40,"eval_count":20}'$'\n'
      elif [[ "$phase" == cancel ]]; then
        fixture_chunk "$peer" '{"message":{"content":"Cancel this partial answer"},"done":false}'$'\n'
        sysread -i "$peer" -s 32 -t 10 chunk 2>/dev/null
        mapfile[${fixture_base}.cancel_eof]="$?"
      else
        fixture_chunk "$peer" '{"message":{"content":"Truncated answer"},"done":false}'$'\n'
      fi
      [[ "$phase" == cancel ]] || zcoder_syswrite_all "$peer" $'0\r\n\r\n'
    fi
    ztcp -c "$peer"
  done
  ztcp -c "$fixture_listener"
) </dev/null >/dev/null 2>&1 &
fixture_server_pid=$!
ztcp -c "$fixture_listener"
fixture_cleanup() {
  http_async_cancel fixture_cleanup
  ui_end
  kill -TERM "$fixture_server_pid" 2>/dev/null || true
  wait "$fixture_server_pid" 2>/dev/null
  zcoder_runtime_cleanup
}
trap fixture_cleanup EXIT
# Keep the model/workspace discovery deterministic; use the real turn loop,
# native TCP transport, JSON parser, tool dispatch, and command-denial policy.
agent_prepare_payload() { REPLY='{"model":"fixture","messages":[],"stream":'"${1:-false}"'}'; }
agent_context_refresh_after_response() { return 0; }
functions[_fixture_stream_preview]="${functions[agent_stream_preview]}"
agent_stream_preview() {
  _fixture_stream_preview
  mapfile[${fixture_base}.preview]="$AGENT_STREAM_CONTENT"
  mapfile[${fixture_base}.history_count]="${#AGENT_MESSAGES}"
  mapfile[${fixture_base}.tool_count]="${#${(M)UI_ROLES:#tool}}"
  mapfile[${fixture_base}.draft]="$INPUT_BUF"
}
command stty rows 24 cols 80 < /dev/tty || exit 1
input_reset; transcript_reset
ui_init || exit 1
agent_user_turn 'Exercise streaming and command denial'
mapfile[${fixture_base}.turn]="$?:${AGENT_LAST_RESPONSE}:${UI_STREAM_INDEX}:${#UI_ROLES}:${#AGENT_MESSAGES}:${AGENT_LAST_PROMPT_TOKENS}:${AGENT_LAST_OUTPUT_TOKENS}"
mapfile[${fixture_base}.tool_state]="${(j: :)UI_TOOL_STATES}"
mapfile[${fixture_base}.history]="${(F)AGENT_MESSAGES}"
agent_ollama_chat '{"model":"fixture","messages":[],"stream":true}' "$OLLAMA_HOST" true
mapfile[${fixture_base}.cancelled]="$?:${AGENT_CANCELLED}:${HTTP_ASYNC_PID}:${HTTP_ASYNC_STREAM_FD}:${UI_STREAM_INDEX}"
mapfile[${fixture_base}.partial]="${UI_CONTENTS[-1]}"
agent_ollama_chat '{"model":"fixture","messages":[],"stream":true}' "$OLLAMA_HOST" true
mapfile[${fixture_base}.truncated]="$?:${HTTP_ERROR}:${HTTP_ASYNC_PID}:${HTTP_ASYNC_STREAM_FD}:${UI_STREAM_INDEX}"
ui_end
mapfile[${fixture_base}.done]=1

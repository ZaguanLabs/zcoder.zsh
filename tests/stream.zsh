# HTTP framing must work at byte boundaries, independently of JSON or curses.
stream_wire=$'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=yes\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: yes\r\n\r\n'
http_stream_reset
stream_decoded=""; stream_feed_status=0
for stream_byte in "${(@s::)stream_wire}"; do
  http_stream_feed "$stream_byte" || { stream_feed_status=$?; break; }
  stream_decoded+="$HTTP_STREAM_OUTPUT"
done
assert_success "streaming HTTP accepts split headers, chunks, and trailers" "$stream_feed_status"
assert_eq Wikipedia "$stream_decoded" "streaming HTTP joins only decoded body bytes"
http_stream_finish
assert_success "complete chunked streams finish successfully" $?
http_stream_reset
http_stream_feed $'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100\r\nfirst'
assert_eq first "$HTTP_STREAM_OUTPUT" "body bytes are published before a large HTTP chunk is complete"
http_stream_finish
assert_failure "truncated chunks cannot finish successfully" $?
http_stream_reset
http_stream_feed $'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK'
assert_eq OK "$HTTP_STREAM_OUTPUT" "streaming HTTP accepts Content-Length responses"
assert_eq done "$HTTP_STREAM_STATE" "Content-Length completes without waiting for connection close"
http_stream_reset
http_stream_feed $'HTTP/1.1 200 OK\r\n\r\nclose framed'
http_stream_finish
assert_success "connection-close framing is supported" $?
for stream_wire in \
  $'HTTP/1.1 500 Error\r\n\r\n' \
  $'HTTP/1.1 200 OK\r\nContent-Length: bogus\r\n\r\n' \
  $'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n' \
  $'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n' \
  $'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\naXX' \
  $'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nextra'; do
  http_stream_reset
  http_stream_feed "$stream_wire"
  assert_failure "invalid streaming HTTP framing fails closed" $?
done

# Use a fresh shell: an earlier non-streaming decode can cache the Unicode
# validation pattern with EXTENDED_GLOB enabled and hide option dependencies.
stream_unicode_result="$(zsh -fc '
  setopt extendedglob
  source "$1/lib/json.zsh"
  source "$1/lib/stream.zsh"
  agent_stream_reset
  agent_stream_record "$2" || { print -r -- "$AGENT_STREAM_ERROR"; exit 1; }
  json_parse_flat_object "${JSON_TOOL_ARGS[1]}" || exit 1
  print -rl -- "$AGENT_STREAM_CONTENT" "$AGENT_STREAM_THINKING" "${JSON_OBJECT[path]}" "$AGENT_STREAM_DONE"
' zcoder-stream-unicode "$PROJECT_DIR" '{"message":{"content":"Streaming \u0026 Async \u003cok\u003e","thinking":"\u4e16\u754c \ud83d\ude00","tool_calls":[{"function":{"name":"read_file","arguments":{"path":"src/a\u0026b.zsh"}}}]},"done":true}')"
assert_success "the first Unicode escapes in a fresh process decode through streaming" $?
assert_eq $'Streaming & Async <ok>\n世界 😀\nsrc/a&b.zsh\n1' "$stream_unicode_result" "streaming decodes escaped content, reasoning, surrogate pairs, and tool paths"

agent_stream_reset
agent_stream_record '{"message":{"thinking":"Check ","content":"Hello "},"done":false}'
agent_stream_record '{"message":{"thinking":"carefully","content":"世界","tool_calls":[{"function":{"index":0,"name":"read_file","arguments":{"path":"one.zsh"}}}]},"done":false}'
agent_stream_record '{"message":{"tool_calls":[{"function":{"index":1,"name":"read_file","arguments":{"path":"two.zsh"}}}]},"done":false}'
agent_stream_record '{"message":{"content":"!"},"done":true,"prompt_eval_count":123,"eval_count":45}'
assert_success "Ollama stream accepts the final usage record" $?
agent_stream_response
json_parse_ollama_response "$REPLY"
assert_success "accumulated stream is a normal Ollama response" $?
assert_eq 'Hello 世界!' "$JSON_RESPONSE_CONTENT" "stream accumulation retains all content including the final chunk"
assert_eq 'Check carefully' "$JSON_RESPONSE_THINKING" "stream accumulation preserves separate reasoning"
assert_eq 'read_file read_file' "${(j: :)JSON_TOOL_NAMES}" "streamed tool calls retain order without merging same-name calls"
assert_eq '{"path":"two.zsh"}' "${JSON_TOOL_ARGS[2]}" "streamed tool arguments remain complete JSON objects"
assert_eq 123 "$JSON_RESPONSE_PROMPT_TOKENS" "final reported prompt usage survives accumulation"
assert_eq 45 "$JSON_RESPONSE_OUTPUT_TOKENS" "final reported output usage survives accumulation"
agent_stream_record '{"done":false}'
assert_failure "records after done are rejected" $?
for stream_record in '{broken' '{"done":false} trailing' '{"message":{"content":"missing done"}}' '{"done":"true"}' '{"error":"model failed"}' '{"message":{"tool_calls":[{"function":{"arguments":{}}}]},"done":true}' '{"message":{"tool_calls":[{"function":{"name":"list_files","arguments":"{}"}}]},"done":true}' '{"message":{"tool_calls":[{"function":{"name":"list_files"}}]},"done":true}'; do
  agent_stream_reset
  agent_stream_record "$stream_record"
  assert_failure "invalid or failed Ollama stream records are rejected" $?
done

for stream_record in \
  '{"message":{"content":"\u00xz"},"done":true}' \
  '{"message":{"content":"\u026"},"done":true}' \
  '{"message":{"content":"\ud83d\uZZZZ"},"done":true}'; do
  agent_stream_reset
  agent_stream_record "$stream_record"
  assert_failure "malformed Unicode escapes still fail closed in streaming" $?
done

# Persisted in-flight previews must restore as explicitly interrupted text.
UI_ACTIVE=1; UI_FOCUS=input; STATE_ENABLED=0
transcript_reset
agent_stream_reset
AGENT_STREAM_CONTENT='Partial answer'; AGENT_STREAM_THINKING='Partial reasoning'
agent_stream_preview
assert_eq 1 "${#UI_ROLES}" "stream previews occupy one transcript entry"
AGENT_STREAM_CONTENT+=' continued'
agent_stream_preview
assert_eq 1 "${#UI_ROLES}" "later deltas update the original preview"
assert_contains "${(F)UI_LINES}" receiving "live preview headers indicate an unfinished response"
transcript_metadata_json 1
stream_metadata="$REPLY"
UI_CONTENTS[1]='Partial answer'
transcript_restore_metadata 1 "$stream_metadata"
assert_contains "${UI_CONTENTS[1]}" 'Interrupted response restored' "saved streaming text never restores as a completed answer"
agent_stream_commit 'Validated answer' 'Validated reasoning'
assert_success "validated assistant output adopts the preview" $?
assert_eq 0 "$UI_STREAM_INDEX" "adopting a preview clears streaming state"
assert_eq 'Validated answer' "${UI_CONTENTS[1]}" "adopting a preview uses validated final text"
assert_eq 1 "${#UI_ROLES}" "finalizing a preview does not duplicate the assistant entry"
agent_stream_reset
AGENT_STREAM_CONTENT='Cancelled fragment'
agent_stream_preview
agent_stream_interrupt
assert_contains "${UI_CONTENTS[2]}" 'partial text only' "interrupted streams clearly label retained partial output"
assert_eq 0 "$UI_STREAM_INDEX" "interruption clears streaming ownership"

# The spool reader retains incomplete records and rejects stale generations.
stream_base="$TEST_TMP/stream-reader"
HTTP_ASYNC_BASE="$stream_base"
: > "${stream_base}.stream"
exec {HTTP_ASYNC_STREAM_FD}< "${stream_base}.stream"
agent_stream_reset
print -rn -- '{"message":{"content":"first"},' >> "${stream_base}.stream"
agent_stream_drain
assert_eq 0 "$AGENT_STREAM_RECORDS" "partial JSON is buffered without being interpreted"
print -r -- '"done":false}' >> "${stream_base}.stream"
agent_stream_drain
assert_eq first "$AGENT_STREAM_CONTENT" "a completed spool record is decoded once"
agent_stream_drain
assert_eq first "$AGENT_STREAM_CONTENT" "polling a temporary spool EOF never replays bytes"
HTTP_ASYNC_BASE="${stream_base}-new"
agent_stream_drain
assert_failure "stale stream state cannot read a new request" $?
HTTP_ASYNC_BASE="$stream_base"
stream_fd="$HTTP_ASYNC_STREAM_FD"
http_async_cleanup
assert_eq '' "$HTTP_ASYNC_STREAM_FD" "stream cleanup releases the reader descriptor"
[[ ! -e "${stream_base}.stream" ]]
assert_success "stream cleanup removes its spool" $?

# Publish bytes exactly when readiness is checked, after an earlier empty spool.
# Completion must be observed before the read that establishes final EOF.
HTTP_ASYNC_BASE="$TEST_TMP/stream-completion-race"
: > "${HTTP_ASYNC_BASE}.stream"
exec {HTTP_ASYNC_STREAM_FD}< "${HTTP_ASYNC_BASE}.stream"
agent_stream_reset
functions[_stream_saved_ready]="${functions[http_async_ready]}"
http_async_ready() {
  if [[ ! -f "${HTTP_ASYNC_BASE}.done" ]]; then
    print -r -- '{"message":{"content":"last bytes"},"done":true}' >> "${HTTP_ASYNC_BASE}.stream"
    print -rn -- 0 > "${HTTP_ASYNC_BASE}.status"
    print -rn -- done > "${HTTP_ASYNC_BASE}.done"
  fi
  return 0
}
agent_stream_ready
agent_stream_ready
assert_success "completion racing with spool growth drains the final bytes" $?
assert_eq 'last bytes' "$AGENT_STREAM_CONTENT" "final bytes are not mistaken for a missing completion record"
assert_eq '' "$AGENT_STREAM_ERROR" "a completion race does not create a false truncation error"
functions[http_async_ready]="${functions[_stream_saved_ready]}"
unfunction _stream_saved_ready
agent_stream_interrupt
http_async_cleanup

functions[_stream_saved_request]="${functions[http_request]}"
http_request() {
  zf_mkdir "${HTTP_ASYNC_BASE}.body"
  HTTP_BODY='cannot be written'; HTTP_ERROR=''
  return 0
}
http_async_start POST /api/chat '{}' fixture.invalid
stream_failed_base="$HTTP_ASYNC_BASE"
for _ in {1..100}; do http_async_ready && break; zselect -t 1 2>/dev/null; done
[[ ! -f "${stream_failed_base}.done" ]]
assert_success "failed result writes never publish a success marker" $?
http_async_collect
assert_failure "failed result writes propagate through worker collection" $?
zf_rmdir "${stream_failed_base}.body"
functions[http_request]="${functions[_stream_saved_request]}"
unfunction _stream_saved_request

test_integration stream || return 0

typeset -g stream_pty_base="$TEST_TMP/stream-pty" stream_pty_output="" stream_pty_chunk=""
stream_pty_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 8.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r stream-ui stream_pty_chunk 2>/dev/null; do
      stream_pty_output+="$stream_pty_chunk"
    done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1 2>/dev/null
  done
  return 1
}
stream_pty_run() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/stream_ui.zsh" "$PROJECT_DIR" "$stream_pty_base"
}
TERM=xterm-256color zpty -b stream-ui stream_pty_run
assert_success "native HTTP streaming fixture starts in a real terminal" $?
stream_pty_wait "$stream_pty_base.preview" 'Hello 世界 &'
assert_success "streamed text reaches the UI before completion across split UTF-8 bytes and Unicode escapes" $?
assert_eq 1 "${mapfile[$stream_pty_base.history_count]:-}" "partial assistant text is not committed to model history"
assert_eq 0 "${mapfile[$stream_pty_base.tool_count]:-}" "streamed tool calls are not dispatched before done"
assert_contains "${mapfile[$stream_pty_base.request_first]:-}" '"stream":true' "ordinary interactive turns request streaming"
zpty -w -n stream-ui 'next draft'
stream_pty_wait "$stream_pty_base.draft" 'next draft'
assert_success "the real HTTP stream leaves draft editing responsive" $?
mapfile[$stream_pty_base.release]=1
stream_pty_wait "$stream_pty_base.turn" '0:Denied command handled.:0:4:4:70:8'
assert_success "streaming completes the real tool loop with one assistant entry per response and final token accounting" $?
assert_contains "${mapfile[$stream_pty_base.tool_state]:-}" failed "streamed commands still obey command denial"
[[ ! -e "${stream_pty_base}.executed" ]]
assert_success "a streamed denied command never executes" $?
assert_contains "${mapfile[$stream_pty_base.history]:-}" 'Inspect first' "canonical model history retains accumulated reasoning"
stream_pty_wait "$stream_pty_base.preview" 'Cancel this partial answer'
assert_success "a second real HTTP stream publishes partial output" $?
zpty -w -n stream-ui $'\e'
stream_pty_wait "$stream_pty_base.cancelled" '130:1:::0'
assert_success "Escape cancels and cleans up the actual HTTP streaming worker" $?
stream_pty_wait "$stream_pty_base.cancel_eof" 5
assert_success "stream cancellation closes the TCP connection observed by the server" $?
assert_contains "${mapfile[$stream_pty_base.partial]:-}" 'partial text only' "cancelled streamed output remains explicitly incomplete"
stream_pty_wait "$stream_pty_base.truncated" '1:Ollama stream ended before done:true:::0'
assert_success "missing done fails the request and releases stream resources" $?
stream_pty_wait "$stream_pty_base.done" 1
stream_pty_exit_status=$?
assert_success "streaming fixture restores the terminal on exit" "$stream_pty_exit_status"
if (( stream_pty_exit_status )); then
  print -r -- "Streaming PTY output tail: ${(V)stream_pty_output[-2000,-1]}"
fi
zpty -d stream-ui
unfunction stream_pty_wait stream_pty_run

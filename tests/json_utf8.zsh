# JSON output must remain UTF-8 even for binary commands and old transcripts.
() {
  local sample='' expected='' quoted='' prefix=''
  local replacement=$'\xef\xbf\xbd'
  local -a cases=(
    $'\x80\xff' "${replacement}${replacement}"
    $'\xc0\xaf' "${replacement}${replacement}"
    $'\xe0\x80\x80' "${replacement}${replacement}${replacement}"
    $'\xed\xa0\x80' "${replacement}${replacement}${replacement}"
    $'\xf4\x90\x80\x80' "${replacement}${replacement}${replacement}${replacement}"
    $'\xf5\x80\x80\x80' "${replacement}${replacement}${replacement}${replacement}"
    $'\xc2' "$replacement"
    $'\xe2\x82' "$replacement"
    $'\xf0\x90\x80' "$replacement"
    $'\xe2\x82A\xc3\xa9' "${replacement}Aé"
    $'\xe2"\\\n' "${replacement}"$'"\\\n'
  )
  local -i i padding
  for (( i=1; i<=${#cases}; i+=2 )); do
    json_quote "${cases[i]}"; quoted="$REPLY"
    json_begin "$quoted"
    assert_success 'malformed UTF-8 still produces a JSON string' $?
    assert_eq "${cases[i+1]}" "$JSON_TOKEN_VALUE" 'JSON replaces malformed prefixes and retains following text'
  done
  # Boundary values exclude overlong forms, surrogates, and values > U+10FFFF.
  sample=$'\xc2\x80\xdf\xbf\xe0\xa0\x80\xed\x9f\xbf\xee\x80\x80\xef\xbf\xbf\xf0\x90\x80\x80\xf4\x8f\xbf\xbf'
  json_quote "$sample"
  assert_eq "\"$sample\"" "$REPLY" 'JSON preserves all valid UTF-8 boundary encodings'
  for padding in 1021 1022 1023 1024; do
    prefix=${(pl:$padding::a:)}
    for sample in é € 😀 $'\xe2\x82A'; do
      _json_utf8_text "$sample"; expected="${prefix}${REPLY}tail"
      json_quote "${prefix}${sample}tail"
      assert_eq "\"$expected\"" "$REPLY" 'UTF-8 repair preserves characters across block boundaries'
    done
  done
  sample=${(pl:100000::é😀:)}
  json_quote "$sample"
  assert_eq "\"$sample\"" "$REPLY" 'large Unicode strings encode without unbounded glob recursion'
  # Encoding must not depend on the caller's locale or MULTIBYTE setting.
  (
    local LC_ALL=C
    unsetopt multibyte
    json_quote $'\xc3\xa9\xff\xf0\x9f\x98\x80'
    [[ "$REPLY" == $'"\xc3\xa9\xef\xbf\xbd\xf0\x9f\x98\x80"' ]]
  )
  assert_success 'JSON repairs UTF-8 in the C locale with MULTIBYTE disabled' $?
}

json_utf8_session_tests() {
  local fixture_dir="$1" session_id="$2" wire='' expected='' raw=''
  local ZCODER_PROFILE=coding ZCODER_COMMAND_POLICY=allow
  local TOOL_RESULT='' TOOL_RESULT_OK=0 TOOL_CANCELLED=0
  local binary=$'\x1f\x8b\x08\x00\xff\xe2\x82text é😀'
  zf_mkdir -p -- "$ZCODER_WORKSPACE"
  tool_run_command "print -rn -- ${(qqqq)binary}" . 2
  assert_success 'run_command captures binary output for the transcript regression' $?
  raw="$TOOL_RESULT"
  expected=$'Exit code: 0\n\x1f�\x08\x00��text é😀'
  mapfile[$fixture_dir/ui_event_count]=2
  mapfile[$fixture_dir/ui_events/000002.role]=tool
  mapfile[$fixture_dir/ui_events/000002.content]="$raw"
  mapfile[$fixture_dir/ui_events/000002.thinking]=''
  mapfile[$fixture_dir/ui_events/000002.time]='21:28'
  _remote_server_session_event "$session_id" 1
  assert_success 'session API loads a saved binary tool-output event' $?
  wire="$REPLY"
  json_parse_flat_object "$wire"
  assert_success 'binary tool-output event is valid JSON' $?
  assert_eq tool "${JSON_OBJECT[role]}" 'repaired event retains its tool role'
  assert_eq 2 "${JSON_OBJECT[seq]}" 'repaired event retains its cursor'
  assert_eq "$expected" "${JSON_OBJECT[content]}" 'saved tool output repairs only malformed UTF-8'
  assert_eq "$raw" "${mapfile[$fixture_dir/ui_events/000002.content]}" 'serving an old event does not rewrite its stored bytes'
  local response_fd=''
  exec {response_fd}> "$TEST_TMP/utf8-response.http"
  _remote_http_send "$response_fd" 200 "$wire"
  assert_success 'session API sends the repaired JSON response' $?
  exec {response_fd}>&-
  # An independent strict decoder catches what the native JSON parser accepts.
  # Python is optional for tests and is never a runtime dependency.
  if (( $+commands[python3] )); then
    python3 -c '
import json, pathlib, sys
header, body = pathlib.Path(sys.argv[1]).read_bytes().split(b"\r\n\r\n", 1)
assert b"Content-Type: application/json" in header
assert b"Content-Length: " + str(len(body)).encode() in header.split(b"\r\n")
event = json.loads(body.decode("utf-8", errors="strict"))
assert event["role"] == "tool" and event["seq"] == 2
' "$TEST_TMP/utf8-response.http"
    assert_success 'strict UTF-8 client loads the complete repaired HTTP response' $?
  fi
  # Cached live events bypass json_quote when replayed. Repair their already
  # serialized JSON at the HTTP boundary without changing framing or escaping.
  local cached=$'{"event":"message","role":"tool","content":"old\xff\\ntext"}'
  local response='' body=''
  exec {response_fd}> "$TEST_TMP/utf8-cached.http"
  _remote_http_send "$response_fd" 200 "$cached"
  exec {response_fd}>&-
  response="${mapfile[$TEST_TMP/utf8-cached.http]}"
  body="${response#*$'\r\n\r\n'}"
  assert_eq $'{"event":"message","role":"tool","content":"old�\\ntext"}' "$body" 'HTTP repairs cached JSON without escaping it twice'
  _http_byte_length "$body"
  assert_contains "$response" "Content-Length: ${REPLY}"$'\r\n' 'HTTP measures Content-Length after repairing cached bytes'
  local publish_function="${functions[_remote_server_publish_json]}"
  local published=''
  {
    _remote_server_publish_json() { published="$1"; }
    remote_server_emit_message tool "$raw"
    json_parse_flat_object "$published"
    assert_eq "$expected" "${JSON_OBJECT[content]}" 'live tool events use the same UTF-8 repair as saved events'
  } always {
    functions[_remote_server_publish_json]="$publish_function"
  }
  _remote_server_session_event "$session_id" 2
  assert_eq '{"event":"none"}' "$REPLY" 'clients can advance past a repaired event'
}

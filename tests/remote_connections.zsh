#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/files zsh/mapfile zsh/datetime zsh/system zsh/net/tcp zsh/zselect
typeset root=${0:A:h:h} base=${TMPDIR:-/tmp}/zcoder-connections-$$/probe server_pid='' library=''
typeset endpoint='' port='' response='' chunk='' peer='' stalled='' partial_fd='' second='' first_response='' second_response='' writer_pid='' turn_pid=''
typeset -a clients=() writers=()
typeset -F started=0 elapsed=0
typeset -i checks=0 result=0 i=0
typeset ollama_listener='' ollama_peer='' ollama_port=''
umask 077
zf_mkdir -p "${base:h}"
for library in util json http; do source "$root/lib/$library.zsh"; done
HTTP_READ_TIMEOUT=2
fail() { print -ru2 -- "FAIL: $*"; exit 1; }
check() { (( checks++ )); "$@" || fail "$*"; }
equal() { [[ "$1" == "$2" ]]; }
contains() { [[ "$1" == *"$2"* ]]; }
cleanup() {
  local exit_code=$? fd=''
  for fd in "${clients[@]}"; do ztcp -c "$fd" 2>/dev/null; done
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null
  fi
  # Also clean up fixture workers when a failed assertion interrupts shutdown.
  [[ -z "$turn_pid" ]] || kill -TERM "$turn_pid" 2>/dev/null
  (( exit_code == 0 )) || print -ru2 -- "${mapfile[$base.log]:-}"
  zf_rm -rf -- "${base:h}"
}
trap cleanup EXIT
wait_value() {
  local suffix="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 8 ))
  while (( EPOCHREALTIME < deadline )); do
    [[ -f "$base.$suffix" && "${mapfile[$base.$suffix]}" == "$expected" ]] && return 0
    zselect -t 2
  done
  return 1
}
wait_present() {
  local suffix="$1"
  local -F deadline=$(( EPOCHREALTIME + 8 ))
  while (( EPOCHREALTIME < deadline )); do
    [[ -s "$base.$suffix" ]] && return 0
    zselect -t 2
  done
  return 1
}
connect_peer() {
  ztcp 127.0.0.1 "$port" || fail 'connect'
  peer=$REPLY; clients+=("$peer")
}
send_request() {
  local fd="$1" method="$2" target="$3" body="${4:-}"
  _http_byte_length "$body"
  zcoder_syswrite_all "$fd" "$method $target HTTP/1.1"$'\r\nAuthorization: Bearer fixture_connection_token\r\nContent-Length: '"$REPLY"$'\r\n\r\n'"$body"
}
collect_response() {
  local fd="$1" part=''
  response=''
  while sysread -i "$fd" -s 32768 -t 2 part 2>/dev/null; do response+="$part"; done
  [[ -n "$response" ]]
}
request() {
  http_request "$1" "$2" "${3:-}" "$endpoint" 'Authorization: Bearer fixture_connection_token'
}
zsh -df "$root/tests/fixtures/remote_connections_server.zsh" "$root" "$base" > "$base.log" 2>&1 &
server_pid=$!
check wait_present endpoint
endpoint="${mapfile[$base.endpoint]}"; endpoint=${endpoint%$'\n'}; port=${endpoint##*:}

# A partial header may occupy a slot, but cannot monopolize request admission.
connect_peer; stalled=$peer
check zcoder_syswrite_all "$stalled" 'POST /'
started=$EPOCHREALTIME
check request GET /v1/hello
elapsed=$(( EPOCHREALTIME - started ))
check contains "$HTTP_BODY" "\"pid\":$server_pid"
(( elapsed < 0.8 )) || fail 'a partial header delayed another request'

# State changes must remain in the process that accepts later requests.
check request POST /v1/session/select '{"id":"1000000000_2"}'
check request GET /v1/hello
check contains "$HTTP_BODY" '"session":"1000000000_2"'

# A second request may overwrite the dispatch globals while the first body is
# incomplete. Completing that body must restore its own method and target.
connect_peer
_http_byte_length '{"id":"1000000000_3"}'
check zcoder_syswrite_all "$peer" $'POST /v1/session/select HTTP/1.1\r\nAuthorization: Bearer fixture_connection_token\r\nContent-Length: '"$REPLY"$'\r\n\r\n{"id":'
check request GET /v1/hello
check contains "$HTTP_BODY" '"session":"1000000000_2"'
check zcoder_syswrite_all "$peer" '"1000000000_3"}'
check collect_response "$peer"
check contains "$response" 'HTTP/1.1 200 OK'
check request GET /v1/hello
check contains "$HTTP_BODY" '"session":"1000000000_3"'

connect_peer
check zcoder_syswrite_all "$peer" $'POST /v1/turn HTTP/1.1\r\nContent-Length: 100\r\n\r\n'
check collect_response "$peer"
check contains "$response" 'HTTP/1.1 401 Unauthorized'
check wait_value pool 0

# Release both requests together. The real start-turn path must publish one
# worker in the parent before the second request tests for a busy turn.
connect_peer; stalled=$peer
check zcoder_syswrite_all "$stalled" 'POST /'
check wait_value pool 1
print -r -- 1 > "$base.pause"
connect_peer; second=$peer
connect_peer
check send_request "$second" POST /v1/turn '{"prompt":"first"}'
check send_request "$peer" POST /v1/turn '{"prompt":"second"}'
zf_rm -f "$base.pause"
check collect_response "$second"; first_response=$response
check collect_response "$peer"; second_response=$response
check contains "$first_response$second_response" 'HTTP/1.1 202 Accepted'
check contains "$first_response$second_response" 'HTTP/1.1 409 Conflict'
check wait_present turn
turn_pid="${mapfile[$base.turn]}"; turn_pid=${turn_pid%$'\n'}

# The worker must close all inherited sockets, including the earlier stalled
# connection. Its peer must see EOF while the turn remains running.
check wait_value pool 0
sysread -i "$stalled" -s 1 -t 0.2 chunk 2>/dev/null; result=$?
check equal "$result" 5
check kill -0 "$turn_pid"

# Make an authenticated client stop reading a large response. Cancellation
# must still reach the original listener and stop the active turn promptly.
connect_peer; partial_fd=$peer
check zcoder_syswrite_all "$partial_fd" 'POST /'
connect_peer; stalled=$peer
check send_request "$stalled" GET '/v1/session?id=large&after=0'
check sysread -i "$stalled" -s 128 -t 8 chunk
check contains "$chunk" 'HTTP/1.1 200 OK'
check wait_present writers
writer_pid="${mapfile[$base.writers]}"
sysread -i "$partial_fd" -s 1 -t 1.5 chunk 2>/dev/null; result=$?
check equal "$result" 5
check kill -0 "$writer_pid"
started=$EPOCHREALTIME
check request POST /v1/cancel '{}'
elapsed=$(( EPOCHREALTIME - started ))
(( elapsed < 0.8 )) || fail 'a blocked response delayed cancellation'
kill -0 "$turn_pid" 2>/dev/null && fail 'cancelled turn worker survived'
check wait_value pool 0
kill -0 "$writer_pid" 2>/dev/null && fail 'expired response writer survived'

# Reject excess clients without allocating an unbounded response worker.
for i in {1..4}; do
  connect_peer
  check wait_value pool "$i"
done
connect_peer
sysread -i "$peer" -s 1 -t 0.5 chunk 2>/dev/null; result=$?
check equal "$result" 5
check wait_value pool 0
check request GET /v1/hello
check wait_value pool 0

# Disconnect recovery must survive descriptor reuse and repeated requests.
for i in {1..12}; do
  connect_peer
  check zcoder_syswrite_all "$peer" 'POST /'
  ztcp -c "$peer"
  check request GET /v1/hello
done
check wait_value pool 0

# An Ollama peer that accepts /api/ps but never responds must not block the
# listener's cancellation endpoint, and the shared check must expire.
check request POST /v1/turn '{"prompt":"model check cancellation"}'
for i in {1..20}; do
  ollama_port=$(( 20000 + RANDOM ))
  if ztcp -l "$ollama_port" 2>/dev/null; then ollama_listener=$REPLY; clients+=("$REPLY"); break; fi
done
[[ -n "$ollama_listener" ]] || fail 'could not open stalled Ollama fixture'
print -rn -- "127.0.0.1:$ollama_port" > "$base.ollama"
check request POST /v1/model/ensure '{}'
check contains "$HTTP_BODY" '"model_status":"warming"'
for i in {1..100}; do
  if ztcp -a -t "$ollama_listener" 2>/dev/null; then ollama_peer=$REPLY; clients+=("$REPLY"); break; fi
  zselect -t 1
done
[[ -n "$ollama_peer" ]] || fail 'the asynchronous residency check never connected'
check sysread -i "$ollama_peer" -s 4096 -t 1 chunk
check contains "$chunk" 'GET /api/ps'
started=$EPOCHREALTIME
check request POST /v1/cancel '{}'
(( EPOCHREALTIME - started < 0.8 )) || fail 'Ollama residency blocked cancellation'
for i in {1..100}; do
  check request GET /v1/model
  [[ "$HTTP_BODY" == *'"model_status":"error"'* ]] && break
  zselect -t 2
done
check contains "$HTTP_BODY" 'timed out'
zf_rm -f "$base.ollama"
ztcp -c "$ollama_peer"
ztcp -c "$ollama_listener"

# Shutdown terminates a blocked writer and closes the listening socket.
zf_rm -f "$base.turn"
check request POST /v1/turn '{"prompt":"shutdown test"}'
check wait_present turn
turn_pid="${mapfile[$base.turn]}"; turn_pid=${turn_pid%$'\n'}
connect_peer; stalled=$peer
check send_request "$stalled" GET '/v1/session?id=large&after=0'
check sysread -i "$stalled" -s 128 -t 8 chunk
check wait_present writers
writers=("${(@s: :)${mapfile[$base.writers]}}")
kill -TERM "$server_pid"
wait "$server_pid" || fail 'server shutdown failed'
server_pid=''
check equal "${mapfile[$base.stopped]}" $'stopped\n'
for writer_pid in "${writers[@]}"; do
  kill -0 "$writer_pid" 2>/dev/null && fail 'shutdown left a response writer alive'
done
kill -0 "$turn_pid" 2>/dev/null && fail 'shutdown left the active turn alive'
ztcp 127.0.0.1 "$port" 2>/dev/null && fail 'shutdown kept the listening socket open'
print -r -- "PASS: $checks remote connection checks"

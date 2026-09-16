#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/datetime zsh/files zsh/mapfile zsh/system zsh/zselect zsh/net/tcp || exit 1
typeset root=${0:A:h:h} scratch='' library='' response='' response_code='' worker_pid=''
scratch=$(mktemp -d /tmp/zcoder-remote-interrupt.XXXXXX) || exit 1
for library in util json mcp http instructions skills transcript tools compact goal agent state input_queue remote; do
  source "$root/lib/$library.zsh"
done
typeset -i checks=0
fail() { print -ru2 -- "FAIL at check $checks: $*"; exit 1; }
check() { (( checks++ )); "$@" || fail "$*"; }
equal() { [[ "$1" == "$2" ]]; }
contains() { [[ "$1" == *"$2"* ]]; }
wait_file() {
  local file=$1
  local -F deadline=$(( EPOCHREALTIME + 8 ))
  while [[ ! -f "$file" ]]; do
    (( EPOCHREALTIME < deadline )) || return 1
    zselect -t 2
  done
  return 0
}
cleanup() {
  local pid="${mapfile[$REMOTE_RUNTIME_DIR/active.pid]:-}"
  [[ "$pid" == <1-> ]] && { kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
  zcoder_runtime_cleanup
  zf_rm -rf "$scratch"
}
trap cleanup EXIT
typeset ZCODER_WORKSPACE=$scratch ZCODER_HOME=$scratch/home ZCODER_SESSIONS_DIR=$scratch/sessions
REMOTE_RUNTIME_DIR=$scratch/remote
REMOTE_MODE=local; ZCODER_STREAM=false; ZCODER_PROFILE=coding; ZCODER_COMMAND_POLICY=deny
AGENT_REQUIRE_FINISH_TOOL=0
zf_mkdir -p "$REMOTE_RUNTIME_DIR/events" "$REMOTE_RUNTIME_DIR/approvals"
agent_prepare_payload() { agent_history_payload_json; REPLY='{"messages":['"$REPLY"']}'; }
agent_context_refresh_after_response() { :; }
agent_ollama_chat() {
  if [[ "${AGENT_MESSAGES[-1]}" == *'"content":"NEW_REQUEST"'* ]]; then
    mapfile[$scratch/replacement]="$1"
    HTTP_BODY='{"message":{"content":"Replacement finished"},"done":true}'
    return 0
  fi
  mapfile[$scratch/started]=$sysparams[pid]
  while true; do zselect -t 10; done
}
_remote_http_send() { response_code=$2; response=$3; }
_remote_http_error() { response_code=$2; response=$3; }
cancel_request() {
  REMOTE_REQUEST_METHOD=POST; REMOTE_REQUEST_TARGET=/v1/cancel; REMOTE_REQUEST_BODY=$1
  _remote_server_dispatch_request ''
}
check state_init
REMOTE_SESSION_ID=$CURRENT_SESSION_ID
# Older abandoned input must not be recovered implicitly by Escape.
check input_queue_open "$CURRENT_SESSION_ID" abandoned
check input_queue_submit "$CURRENT_SESSION_ID" abandoned stale steer STALE_REQUEST
INPUT_QUEUE_TURN_ID=abandoned
check input_queue_close true
check _remote_server_start_turn OLD_REQUEST '' 1 current
check wait_file "$scratch/started"
worker_pid=${mapfile[$scratch/started]}
check input_queue_submit "$CURRENT_SESSION_ID" current replacement steer NEW_REQUEST
cancel_request '{"session_id":"'"$CURRENT_SESSION_ID"'","turn_id":"wrong","continue_queued":true}'
check equal "$response_code" 409
check kill -0 "$worker_pid"
cancel_request '{"session_id":"'"$CURRENT_SESSION_ID"'","turn_id":"current","continue_queued":"true"}'
check equal "$response_code" 400
check kill -0 "$worker_pid"
cancel_request '{"session_id":"'"$CURRENT_SESSION_ID"'","turn_id":"current","continue_queued":true}'
check equal "$response_code" 200
check contains "$response" '"continued":true'
kill -0 "$worker_pid" 2>/dev/null && fail 'interrupted worker survived'
check wait_file "$REMOTE_RUNTIME_DIR/worker.done"
check contains "${mapfile[$scratch/replacement]}" NEW_REQUEST
[[ ${mapfile[$scratch/replacement]} != *STALE_REQUEST* ]] || fail 'takeover consumed abandoned input'
check input_queue_status "$CURRENT_SESSION_ID" replacement
check contains "$REPLY" consumed
check input_queue_status "$CURRENT_SESSION_ID" stale
check contains "$REPLY" accepted
check equal "${mapfile[$REMOTE_RUNTIME_DIR/worker.done]}" 0
_remote_server_reap_worker

# No queued input for this turn means an ordinary stop, even with stale input.
zf_rm "$scratch/started"
check _remote_server_start_turn OLD_REQUEST '' 1 empty
check wait_file "$scratch/started"
cancel_request '{"session_id":"'"$CURRENT_SESSION_ID"'","turn_id":"empty","continue_queued":true}'
check equal "$response_code" 200
[[ "$response" != *continued* && ! -f "$REMOTE_RUNTIME_DIR/active.pid" ]] || fail 'empty queue unexpectedly continued'

# Legacy/API cancellation retains explicit recovery semantics.
zf_rm "$scratch/started"
check _remote_server_start_turn OLD_REQUEST '' 1 legacy
check wait_file "$scratch/started"
check input_queue_submit "$CURRENT_SESSION_ID" legacy kept steer NEW_REQUEST
cancel_request '{}'
check equal "$response_code" 200
[[ "$response" != *continued* ]] || fail 'legacy stop automatically continued'
check input_queue_status "$CURRENT_SESSION_ID" kept
check contains "$REPLY" accepted

# A prompt still waiting for warm-up can also be replaced by its queued input.
zf_rm "$scratch/replacement"
check _remote_server_queue_turn OLD_REQUEST 1
check input_queue_submit "$CURRENT_SESSION_ID" "$REMOTE_TURN_ID" warming steer NEW_REQUEST
cancel_request '{"session_id":"'"$CURRENT_SESSION_ID"'","turn_id":"'"$REMOTE_TURN_ID"'","continue_queued":true}'
check contains "$response" '"continued":true'
check wait_file "$REMOTE_RUNTIME_DIR/worker.done"
check input_queue_status "$CURRENT_SESSION_ID" warming
check contains "$REPLY" consumed
_remote_server_reap_worker

# The real client event loop must keep polling after an acknowledged takeover.
UI_ACTIVE=1; REMOTE_INPUT_SUPPORTED=true; REMOTE_SESSIONS_SUPPORTED=0
STATE_ENABLED=0
ui_activity_begin() { :; }
ui_activity_end() { :; }
ui_append_message() { :; }
ui_refresh_all() { :; }
ui_draw_chat() { :; }
agent_emit() { :; }
agent_set_status() { :; }
remote_client_idle_cancel() { :; }
remote_client_model_ensure() { :; }
remote_client_reconcile_session() { :; }
typeset -i polls=0 cancel_calls=0 event_reads=0
typeset cancel_body='' continued_response=true
# UI cancellation uses status 130, not a generic error.
ui_poll_remote_turn() { (( polls++ )); (( polls == 1 )) && return 130; return 0; }
remote_client_request() {
  case "$1:$2" in
    POST:/v1/turn) HTTP_BODY='{"turn_id":"client-turn"}' ;;
    POST:/v1/cancel)
      (( cancel_calls++ )); cancel_body=$3
      HTTP_BODY='{"ok":true,"continued":'"$continued_response"'}'
      ;;
    GET:/v1/events*) (( event_reads++ )); HTTP_BODY='{"event":"complete","exit_code":0,"seq":1}' ;;
    *) return 1 ;;
  esac
  return 0
}
check remote_client_user_turn OLD_REQUEST
check equal "$cancel_calls:$event_reads" 1:1
check contains "$cancel_body" '"continue_queued":true'
continued_response=false; polls=0; event_reads=0
remote_client_user_turn OLD_REQUEST
check equal "$?" 130
check equal "$event_reads" 0
print -r -- "PASS: remote queue interruption ($checks checks)"

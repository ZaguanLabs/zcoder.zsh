#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect || exit 1
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json mcp http instructions skills transcript tools compact goal agent state input_queue input terminal ui; do
  source "$fixture_root/lib/${fixture_lib}.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_WORKSPACE="${fixture_base:h}" ZCODER_SESSIONS_DIR="$fixture_base.sessions"
typeset -g ZCODER_TOOL_EXPOSURE=full ZCODER_COMMAND_POLICY=deny ZCODER_STREAM=false
typeset -gi AGENT_REQUIRE_FINISH_TOOL=0 fixture_request=0
typeset -g fixture_phase=deliver
agent_prepare_payload() { agent_history_payload_json; REPLY='{"messages":['"$REPLY"']}'; }
agent_context_refresh_after_response() { :; }
http_async_ready() { [[ -f "$fixture_base.release_$fixture_phase" ]]; }
agent_ollama_chat() {
  (( fixture_request++ ))
  mapfile[$fixture_base.request_$fixture_request]="$1"
  mapfile[$fixture_base.started]="$fixture_phase:$fixture_request"
  if (( fixture_request == 1 )) || [[ "$fixture_phase" == cancel ]]; then
    ui_wait_for_generation
    if (( $? == 130 )); then AGENT_CANCELLED=1; return 130; fi
  fi
  if (( fixture_request == 1 )); then
    HTTP_BODY='{"message":{"content":"Reading","tool_calls":[{"function":{"name":"read_file","arguments":{"path":"input-queue-file"}}}]},"done":true}'
  else
    HTTP_BODY='{"message":{"content":"Complete"},"done":true}'
  fi
}
functions[_fixture_activity_input]="${functions[ui_activity_input]}"
ui_activity_input() {
  _fixture_activity_input "$@"
  local -i result=$?
  _input_queue_write "$fixture_base.draft" "$INPUT_BUF"
  input_queue_request list "$CURRENT_SESSION_ID" '' '' '' ''
  mapfile[$fixture_base.pending]="$REPLY"
  return "$result"
}
command stty rows 24 cols 100 < /dev/tty || exit 1
trap 'ui_end; zcoder_runtime_cleanup' EXIT
mapfile[$ZCODER_WORKSPACE/input-queue-file]='file evidence'
state_init || exit 1
input_reset
ui_init || exit 1
agent_user_turn 'Initial request'
mapfile[$fixture_base.result]="$?:$fixture_request:$INPUT_BUF"
agent_history_payload_json
mapfile[$fixture_base.history]="$REPLY"
state_new_session
fixture_phase=cancel
agent_user_turn 'Cancelled request'
mapfile[$fixture_base.cancelled]="$?:$INPUT_BUF"
input_queue_request list "$CURRENT_SESSION_ID" '' '' '' ''
mapfile[$fixture_base.cancel_pending]="$REPLY"
ui_end
mapfile[$fixture_base.done]=1

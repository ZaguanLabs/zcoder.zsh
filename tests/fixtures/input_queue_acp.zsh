#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect || exit 1
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json mcp http instructions skills transcript tools compact goal agent state input_queue remote acp; do
  source "$fixture_root/lib/${fixture_lib}.zsh"
done
typeset -g ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_WORKSPACE="${fixture_base:h}" ZCODER_SESSIONS_DIR="$fixture_base.sessions"
typeset -g ZCODER_TOOL_EXPOSURE=full ZCODER_COMMAND_POLICY=deny
typeset -gi AGENT_REQUIRE_FINISH_TOOL=0 fixture_request=0
agent_prepare_payload() { agent_history_payload_json; REPLY='{"messages":['"$REPLY"']}'; }
agent_context_refresh_after_response() { :; }
_acp_configure_workspace() { :; }
agent_ollama_chat() {
  (( fixture_request++ ))
  mapfile[$fixture_base.request_$fixture_request]="$1"
  mapfile[$fixture_base.started]="$INPUT_QUEUE_TURN_ID"
  if (( fixture_request == 1 )); then
    local -F deadline=$(( EPOCHREALTIME + 12 ))
    while [[ ! -f "$fixture_base.release" ]]; do
      (( EPOCHREALTIME < deadline )) || return 1
      zselect -t 1
    done
  fi
  HTTP_BODY='{"message":{"content":"Complete"},"done":true}'
}
state_init || exit 1
ACP_SESSION_CWD[$CURRENT_SESSION_ID]="$ZCODER_WORKSPACE"
ACP_SESSION_MCP[$CURRENT_SESSION_ID]='[]'
mapfile[$fixture_base.session]="$CURRENT_SESSION_ID"
trap 'acp_shutdown; zcoder_runtime_cleanup' EXIT
acp_main

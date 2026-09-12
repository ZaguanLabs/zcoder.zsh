#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json mcp http instructions skills transcript tools compact goal agent state input terminal process ui overlays; do source "$fixture_root/lib/${fixture_lib}.zsh"; done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_WORKSPACE="${fixture_base}.workspace" ZCODER_HOME="${fixture_base}.home" ZCODER_SYNC_OUTPUT=false
typeset -g ZCODER_TOOL_EXPOSURE=full ZCODER_WARMUP=false
typeset -gi STATE_ENABLED=0 MCP_STARTUP_TIMEOUT=5 fixture_second=0
zf_mkdir -p "$ZCODER_WORKSPACE" "$ZCODER_HOME"
zjson_quote "$fixture_root/tests/fixtures/mcp_connect_server.zsh"; fixture_server_json="$REPLY"
zjson_quote "$fixture_base"; fixture_base_json="$REPLY"
mapfile[$ZCODER_HOME/mcp.json]='{"mcpServers":{"fixture":{"command":"zsh","args":['"$fixture_server_json,$fixture_base_json"']},"second":{"command":"zsh","args":[]}}}'
functions[_fixture_broker]="${functions[_mcp_broker_main]}"
_mcp_broker_main() {
  trap - EXIT INT TERM HUP WINCH
  if [[ "${mapfile[$fixture_base.phase]}" == startup ]]; then
    mapfile[$fixture_base.started]=startup
    while true; do zselect -t 5; done
  fi
  _fixture_broker "$@"
}
functions[_fixture_connect]="${functions[mcp_connect]}"
mcp_connect() {
  if [[ "$1" == second ]]; then (( fixture_second++ )); return 1; fi
  _fixture_connect "$@"
}
functions[_fixture_input]="${functions[ui_activity_input]}"
ui_activity_input() {
  _fixture_input "$@"
  local -i input_result=$?
  mapfile[$fixture_base.draft]="$INPUT_BUF"
  mapfile[$fixture_base.state]="${SCREEN_W}:${UI_FOCUS}:${UI_BLOCK_OPEN[1]}:${UI_MODAL_ACTIVE}"
  return "$input_result"
}
functions[_fixture_mcp_draw]="${functions[_ui_mcp_draw]}"
_ui_mcp_draw() { _fixture_mcp_draw; mapfile[$fixture_base.inspector]="${MCP_STATUS[fixture]}"; }
agent_ollama_chat() { mapfile[$fixture_base.sent]=1; return 1; }
trap 'mcp_shutdown_all; ui_end' EXIT
mcp_load || exit 1
command stty rows 24 cols 80 < /dev/tty
ui_append_message assistant 'Fold this entry.'
ui_init || exit 1
mapfile[$fixture_base.tty]="$TTY"
mapfile[$fixture_base.phase]=startup
mcp_connect_all
mapfile[$fixture_base.start_cancelled]="$?:${MCP_CONNECT_CANCELLED}:${#MCP_BROKER_PID}:${fixture_second}:${UI_ACTIVITY_DEPTH}"
mapfile[$fixture_base.phase]=discover_cancel
agent_user_turn 'A prompt that must not reach Ollama after cancellation.'
mapfile[$fixture_base.turn_cancelled]="$?:${AGENT_CANCELLED}:${#MCP_BROKER_PID}:${fixture_second}:${MCP_STATUS[fixture]}"
mapfile[$fixture_base.discover_methods]="${mapfile[$fixture_base.methods]}"
MCP_NAMES=(fixture)
mapfile[$fixture_base.phase]=pages_cancel
mcp_connect fixture
mapfile[$fixture_base.pages_cancelled]="$?:${MCP_CONNECT_CANCELLED}:${MCP_SERVER_TOOLS[fixture]:-empty}:${#MCP_TOOL_NAMES}"
mapfile[$fixture_base.phase]=success
mcp_connect fixture || exit 2
mapfile[$fixture_base.success]="${MCP_STATUS[fixture]}:${#MCP_TOOL_NAMES}:${MCP_PROTOCOL[fixture]}"
mcp_broker_stop fixture; MCP_STATUS[fixture]=configured
mapfile[$fixture_base.phase]=legacy_cancel
mcp_connect fixture
mapfile[$fixture_base.legacy_cancelled]="$?:${MCP_CONNECT_CANCELLED}:${#MCP_BROKER_PID}"
mapfile[$fixture_base.phase]=legacy_success
mcp_connect fixture || exit 3
mapfile[$fixture_base.legacy_success]="${MCP_STATUS[fixture]}:${#MCP_TOOL_NAMES}:${MCP_PROTOCOL[fixture]}"
mcp_broker_stop fixture; MCP_STATUS[fixture]=configured
MCP_STARTUP_TIMEOUT=1
mapfile[$fixture_base.phase]=discover_timeout
: >| "$fixture_base.methods"
mcp_connect fixture
mapfile[$fixture_base.timeout]="$?:${MCP_CONNECT_CANCELLED}:${#MCP_BROKER_PID}:${mapfile[$fixture_base.methods]}"
mapfile[$fixture_base.phase]=success
mcp_connect fixture || exit 4
mapfile[$fixture_base.phase]=discover_overlay
ui_mcp_servers
mapfile[$fixture_base.overlay_done]="${UI_MODAL_ACTIVE}:${UI_ACTIVITY_DEPTH}:${MCP_STATUS[fixture]}"
mcp_shutdown_all
ui_end
mapfile[$fixture_base.done]=1

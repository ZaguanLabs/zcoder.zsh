#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json mcp http instructions skills transcript tools compact goal agent state input terminal process ui overlays; do source "$fixture_root/lib/${fixture_lib}.zsh"; done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_WORKSPACE="${fixture_base}.workspace" ZCODER_HOME="${fixture_base}.home" ZCODER_SYNC_OUTPUT=false
typeset -gi STATE_ENABLED=0 fixture_approvals=0 MCP_REQUEST_TIMEOUT=10
zf_mkdir -p "$ZCODER_WORKSPACE" "$ZCODER_HOME"
json_quote "$fixture_root/tests/fixtures/mcp_wait_server.zsh"; fixture_server_json="$REPLY"
json_quote "$fixture_base"; fixture_base_json="$REPLY"
mapfile[$ZCODER_HOME/mcp.json]='{"mcpServers":{"fixture":{"command":"zsh","args":['"$fixture_server_json,$fixture_base_json"']}}}'
trap 'mapfile[${fixture_base}.parent_exit]=1; mcp_shutdown_all; ui_end' EXIT
mcp_load; mcp_connect fixture || exit 1
fixture_original_pid="${MCP_BROKER_PID[fixture]}"
functions[_fixture_input]="${functions[ui_activity_input]}"
ui_activity_input() {
  _fixture_input "$@"
  local -i input_result=$?
  mapfile[${fixture_base}.draft]="$INPUT_BUF"
  mapfile[${fixture_base}.state]="${SCREEN_W}:${UI_FOCUS}:${UI_BLOCK_OPEN[1]}"
  return "$input_result"
}
functions[_fixture_approval_draw]="${functions[_ui_approval_draw]}"
_ui_approval_draw() { _fixture_approval_draw; mapfile[${fixture_base}.approval]="$fixture_approvals"; }
functions[_fixture_approval]="${functions[ui_confirm_external_action]}"
ui_confirm_external_action() { (( fixture_approvals++ )); _fixture_approval "$@"; }
command stty rows 24 cols 80 < /dev/tty
ui_append_message assistant 'Fold this stable entry.'
ui_init || exit 1
mapfile[${fixture_base}.tty]="$TTY"
ui_set_status 'Tool: MCP read'
tool_dispatch mcp__fixture__read '{"phase":"first","wait":true}'
mapfile[${fixture_base}.success]="${TOOL_RESULT_OK}:${MCP_STATUS[fixture]}:$(( MCP_BROKER_PID[fixture] == fixture_original_pid )):$TOOL_RESULT"
tool_dispatch mcp__fixture__read '{"phase":"cancel","wait":true,"partial":true}'
fixture_result=$?
mapfile[${fixture_base}.cancelled]="${fixture_result}:${TOOL_CANCELLED}:${MCP_STATUS[fixture]}:${#MCP_BROKER_PID}:${UI_ACTIVITY_DEPTH}:$TOOL_RESULT"
[[ -f ${fixture_base}.parent_exit ]] && mapfile[${fixture_base}.inherited_cleanup]=bad || mapfile[${fixture_base}.inherited_cleanup]=clean
mcp_connect fixture || exit 2
tool_dispatch mcp__fixture__read '{"phase":"fresh"}'
mapfile[${fixture_base}.fresh]="${TOOL_RESULT_OK}:$TOOL_RESULT"
tool_dispatch mcp__fixture__write '{"phase":"denied"}'
mapfile[${fixture_base}.denied]="${TOOL_RESULT_OK}:${mapfile[${fixture_base}.calls]}"
tool_dispatch mcp__fixture__write '{"phase":"write","wait":true}'
mapfile[${fixture_base}.write_cancelled]="${TOOL_CANCELLED}:$TOOL_RESULT"
mcp_connect fixture || exit 3
MCP_REQUEST_TIMEOUT=1
tool_dispatch mcp__fixture__read '{"phase":"timeout","wait":true,"partial":true}'
mapfile[${fixture_base}.timeout]="${TOOL_RESULT_OK}:${TOOL_CANCELLED}:${MCP_STATUS[fixture]}:${#MCP_BROKER_PID}:$TOOL_RESULT"
mcp_shutdown_all
ui_end
mapfile[${fixture_base}.done]=1

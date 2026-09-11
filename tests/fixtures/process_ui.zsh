#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect || exit 1
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json mcp http instructions skills transcript tools compact goal agent state input terminal process ui overlays; do
  source "$fixture_root/lib/${fixture_lib}.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_WORKSPACE="${fixture_base:h}" ZCODER_COMMAND_POLICY=ask ZCODER_SYNC_OUTPUT=false
typeset -gi STATE_ENABLED=0 AGENT_REQUIRE_FINISH_TOOL=0 fixture_requests=0 fixture_processes=0
functions[_fixture_approval_draw]="${functions[_ui_approval_draw]}"
_ui_approval_draw() {
  _fixture_approval_draw
  mapfile[${fixture_base}.approval]=1
  [[ "$ZCODER_PROFILE" == sysadmin ]] && mapfile[${fixture_base}.sysadmin]=1
  return 0
}
functions[_fixture_approval_input]="${functions[_ui_approval_input]}"
_ui_approval_input() {
  _fixture_approval_input
  if [[ "$ZCODER_PROFILE" == sysadmin && -n "$modal_ch" ]]; then
    mapfile[${fixture_base}.sysadmin_choice]="${modal_ch}:${modal_done}"
  fi
  return 0
}
functions[_fixture_activity_input]="${functions[ui_activity_input]}"
ui_activity_input() {
  _fixture_activity_input "$@"
  local -i input_result=$?
  mapfile[${fixture_base}.draft]="$INPUT_BUF"
  mapfile[${fixture_base}.fold]="$UI_FOCUS:${UI_BLOCK_OPEN[1]}"
  return "$input_result"
}
functions[_fixture_process_run]="${functions[tool_process_run]}"
tool_process_run() { (( fixture_processes++ )); _fixture_process_run "$@"; }
typeset -g fixture_command="print -r -- started > ${(q)fixture_base}.started; print -r -- PRIVATE_\"WORKER\"_TTY > /dev/tty; trap '' TERM; sleep 30 & print -r -- \$! > ${(q)fixture_base}.child; wait"
agent_ollama_chat() {
  (( fixture_requests++ ))
  json_quote "$fixture_command"
  HTTP_BODY='{"message":{"content":"","tool_calls":[{"function":{"name":"run_command","arguments":{"command":'"$REPLY"'}}},{"function":{"name":"run_command","arguments":{"command":"print should-not-run > process-pty.should-not-run"}}}]}}'
  HTTP_ERROR=''
  return 0
}
command stty rows 24 cols 80 < /dev/tty || exit 1
trap 'tool_process_cleanup; ui_end' EXIT
input_reset; transcript_reset
ui_init || exit 1
agent_user_turn 'Run the two approved commands.'
mapfile[${fixture_base}.cancelled]="$?:${ZCODER_COMMAND_POLICY}:${fixture_requests}:${UI_ACTIVITY_DEPTH}:${TOOL_PROCESS_NAME}:${TOOL_PROCESS_PID}"
mapfile[${fixture_base}.history]="${(F)AGENT_MESSAGES}"
TOOL_CANCELLED=0
mapfile[${fixture_base}.search-input]='process needle'
fixture_processes=0
tool_dispatch search '{"query":"process needle","path":"process-pty.search-input"}'
mapfile[${fixture_base}.search]="${TOOL_RESULT_OK}:${fixture_processes}:$TOOL_RESULT"
ZCODER_PROFILE=sysadmin; ZCODER_COMMAND_POLICY=allow; fixture_processes=0
tool_dispatch run_command '{"command":"print must-ask-again"}'
mapfile[${fixture_base}.sysadmin_denied]="${TOOL_RESULT_OK}:${fixture_processes}"
ZCODER_PROFILE=coding
ZCODER_COMMAND_POLICY=deny; fixture_processes=0
tool_dispatch run_command '{"command":"print denied"}'
mapfile[${fixture_base}.denied]="${TOOL_RESULT_OK}:${fixture_processes}"
ZCODER_COMMAND_POLICY=allow
agent_user_turn "! print bang-started > ${(q)fixture_base}.bang_started; sleep 30"
mapfile[${fixture_base}.bang_cancelled]="$?:${fixture_requests}:${UI_ACTIVITY_DEPTH}:${TOOL_PROCESS_NAME}:${UI_CURRENT_TOOL}"
mapfile[${fixture_base}.bang_history]="${(F)AGENT_MESSAGES}"
ui_end
mapfile[${fixture_base}.done]=1

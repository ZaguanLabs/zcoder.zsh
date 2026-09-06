#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect zsh/net/tcp
typeset -g fixture_root="$1"
typeset -gx fixture_base="$2"
for fixture_lib in util json mcp http instructions skills transcript tools compact goal agent state input terminal process ui overlays harnesses delegate; do
  source "$fixture_root/lib/${fixture_lib}.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=alpha ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_WORKSPACE="${fixture_base:h}" ZCODER_SYNC_OUTPUT=false
typeset -gi STATE_ENABLED=0
OLLAMA_HOST="${mapfile[$fixture_base.endpoint]}"
path=("$fixture_base.bin" "${path[@]}")
[[ "${commands[opencode]:-}" == "$fixture_base.bin/opencode" ]] || exit 3
ZCODER_OPENCODE_MODEL=provider/alpha
trap 'http_async_cancel fixture; tool_process_cleanup; ui_end; zcoder_runtime_cleanup' EXIT
functions[_fixture_input]="${functions[ui_activity_input]}"
ui_activity_input() {
  _fixture_input "$@"
  local -i result=$?
  mapfile[$fixture_base.draft]="$INPUT_BUF"
  mapfile[$fixture_base.view]="${UI_FOCUS}:${UI_BLOCK_OPEN[1]}:${SCREEN_W}"
  return "$result"
}
functions[_fixture_list]="${functions[_ui_modal_list_draw]}"
_ui_modal_list_draw() {
  _fixture_list
  mapfile[$fixture_base.modal]="${mapfile[$fixture_base.phase]}:${modal_selected}:${UI_MODAL_ACTIVE}"
}
functions[_fixture_wait]="${functions[ui_wait_for_models]}"
ui_wait_for_models() {
  [[ "${mapfile[$fixture_base.phase]}" == timeout ]] && model_discovery_deadline=$(( EPOCHREALTIME + 1.0 ))
  _fixture_wait
}
functions[_fixture_process]="${functions[tool_process_run]}"
tool_process_run() {
  if [[ "${mapfile[$fixture_base.phase]}" == opencode_timeout ]]; then
    _fixture_process "$1" 1 "${@[3,-1]}"
  else _fixture_process "$@"
  fi
}
command stty rows 24 cols 80 < /dev/tty
ui_append_message assistant 'Original conversation'
ui_init || exit 1
mapfile[$fixture_base.tty]="$TTY"
# Keep a real completed warm-up worker owned by the parent during discovery.
http_async_start GET /warmup '' "$OLLAMA_HOST" || exit 2
while ! http_async_ready; do zselect -t 1; done
typeset -g warmup_pid="$HTTP_ASYNC_PID" warmup_base="$HTTP_ASYNC_BASE"
for phase in cancel success malformed timeout; do
  mapfile[$fixture_base.phase]="$phase"
  ui_set_status Ready
  ui_select_model
  mapfile[$fixture_base.result_$phase]="$?:${ZCODER_MODEL}:${UI_STATUS}:${#OLLAMA_MODELS}:${UI_ACTIVITY_DEPTH}:${UI_MODAL_ACTIVE}"
done
mapfile[$fixture_base.warmup_owned]="$(( HTTP_ASYNC_PID == warmup_pid )):$([[ "$HTTP_ASYNC_BASE" == "$warmup_base" ]] && print 1)"
http_async_collect
mapfile[$fixture_base.warmup_result]="$?:$HTTP_BODY"
for phase in opencode_cancel opencode_success opencode_failure opencode_large opencode_timeout; do
  mapfile[$fixture_base.phase]="$phase"
  ui_set_status Ready
  ui_select_opencode_model
  mapfile[$fixture_base.result_$phase]="$?:${ZCODER_OPENCODE_MODEL}:${UI_STATUS}:${#DELEGATE_MODELS}:${UI_ACTIVITY_DEPTH}:${UI_MODAL_ACTIVE}:${TOOL_PROCESS_NAME}"
done
typeset -a scratch=("$ZCODER_RUNTIME_DIR"/(http|process).*(N))
mapfile[$fixture_base.scratch]="${#scratch}"
ui_end
mapfile[$fixture_base.done]=1

#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile || exit 1
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json transcript input ui; do
  source "$fixture_root/lib/${fixture_lib}.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture
typeset -g ZCODER_WORKSPACE="$fixture_root" OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -gi fixture_status_applied=0 fixture_header_paints=0 fixture_chat_paints=0 fixture_input_paints=0
functions[_fixture_header]="${functions[_ui_paint_header]}"
functions[_fixture_chat]="${functions[_ui_paint_chat]}"
functions[_fixture_input]="${functions[_ui_paint_input]}"
_ui_paint_header() { (( fixture_header_paints++ )); _fixture_header "$@"; }
_ui_paint_chat() { (( fixture_chat_paints++ )); _fixture_chat "$@"; }
_ui_paint_input() { (( fixture_input_paints++ )); _fixture_input "$@"; }
fixture_state() {
  mapfile[${fixture_base}.state]="${UI_FOCUS}:${UI_SELECTED_EVENT}:${UI_BLOCK_OPEN[1]}:${SCREEN_W}:${UI_ACTIVITY_DEPTH}"
  mapfile[${fixture_base}.draft]="$INPUT_BUF"
  mapfile[${fixture_base}.paints]="${fixture_header_paints}:${fixture_chat_paints}:${fixture_input_paints}"
}
functions[_fixture_activity_input]="${functions[ui_activity_input]}"
ui_activity_input() {
  _fixture_activity_input "$@"
  local -i result=$?
  fixture_state
  return "$result"
}
http_async_ready() {
  if (( ! fixture_status_applied )) && [[ "${mapfile[${fixture_base}.status]:-}" == 1 ]]; then
    ui_set_status Thinking
    ui_draw_header
    fixture_status_applied=1
    fixture_state
    mapfile[${fixture_base}.status_done]=1
  fi
  [[ "${mapfile[${fixture_base}.release]:-}" == 1 ]]
}
delegate_async_ready() { return 1; }
delegate_async_timed_out() { return 1; }
command stty rows 24 cols 80 < /dev/tty || exit 1
trap 'ui_end' EXIT
input_reset
transcript_reset
ui_append_message assistant "First visible answer" "First private reasoning"
ui_append_message assistant "Second visible answer"
ui_init || exit 1
mapfile[${fixture_base}.tty]="$TTY"
ui_wait_for_generation
mapfile[${fixture_base}.completed]="$?:${UI_ACTIVITY_DEPTH}"
mapfile[${fixture_base}.phase]=delegate
ui_wait_for_delegate
mapfile[${fixture_base}.cancelled]="$?:${UI_ACTIVITY_DEPTH}"
ui_end
mapfile[${fixture_base}.done]=1

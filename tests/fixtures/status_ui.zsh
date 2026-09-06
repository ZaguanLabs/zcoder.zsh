#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile || exit 1
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json transcript input terminal ui overlays; do source "$fixture_root/lib/${fixture_lib}.zsh"; done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_SYNC_OUTPUT=false
typeset -g ZCODER_WORKSPACE="$fixture_root" OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -gi fixture_header=0 fixture_chat=0 fixture_input=0 fixture_notified=0 fixture_modal_header=0
functions[_fixture_header]="${functions[_ui_paint_header]}"
functions[_fixture_chat]="${functions[_ui_paint_chat]}"
functions[_fixture_input]="${functions[_ui_paint_input]}"
_ui_paint_header() { (( fixture_header++ )); _fixture_header "$@"; }
_ui_paint_chat() { (( fixture_chat++ )); _fixture_chat "$@"; }
_ui_paint_input() { (( fixture_input++ )); _fixture_input "$@"; }
functions[_fixture_approval_draw]="${functions[_ui_approval_draw]}"
_ui_approval_draw() { _fixture_approval_draw; mapfile[${fixture_base}.modal]=1; }
functions[_fixture_approval_input]="${functions[_ui_approval_input]}"
_ui_approval_input() {
  if (( ! fixture_notified )) && [[ ${mapfile[${fixture_base}.notify]:-} == 1 ]]; then
    ui_append_message error 'Connection lost'
    ui_set_status Ready
    ui_refresh_all
    fixture_notified=1
    mapfile[${fixture_base}.notice]="${UI_MODAL_ACTIVE}:$(( fixture_header == fixture_modal_header ))"
  fi
  _fixture_approval_input
}
command stty rows 24 cols 60 < /dev/tty || exit 1
trap 'ui_end' EXIT
input_reset; transcript_reset
ui_append_message assistant 'Stable transcript'
ui_set_status 'Thinking 1'
ui_init || exit 1
# Baseline after entering activity so later editor paints count actual edits.
ui_activity_begin
fixture_header=0; fixture_chat=1; fixture_input=1
typeset -g fixture_ch='' fixture_key='' fixture_mouse=''
while true; do
  ui_poll_resize
  zcurses timeout input_win 50
  terminal_read_event input_win fixture_ch fixture_key fixture_mouse
  if [[ "$fixture_ch" == $'\x07' ]]; then
    fixture_modal_header=$fixture_header
    ui_confirm_command 'Only record the answer; never execute a command.'
    mapfile[${fixture_base}.answer]="$REPLY"
  else
    ui_activity_input "$fixture_ch" "$fixture_key"
    (( $? == 130 )) && break
  fi
  if (( fixture_header >= 2 )); then
    mapfile[${fixture_base}.underlay]="${fixture_chat}:${fixture_input}"
    mapfile[${fixture_base}.animated]=1
  fi
  [[ ${mapfile[${fixture_base}.expire]:-} == 1 ]] && UI_NOTICE_UNTIL=0
  mapfile[${fixture_base}.draft]="$INPUT_BUF"
  mapfile[${fixture_base}.visible]="$UI_STATUS_DISPLAY"
done
ui_activity_end
ui_end
mapfile[${fixture_base}.done]=1

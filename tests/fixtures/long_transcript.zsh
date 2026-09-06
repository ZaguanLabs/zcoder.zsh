#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/datetime zsh/mapfile
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json skills transcript input terminal ui; do source "$fixture_root/lib/${fixture_lib}.zsh"; done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_WORKSPACE="$fixture_root"
typeset -gi STATE_ENABLED=0 rendered=0 curses_calls=0 chat_paints=0 i=0
zcurses() {
  (( curses_calls++ ))
  [[ "$1:$2" == clear:chat_win ]] && (( chat_paints++ ))
  return 0
}
functions[_fixture_render]="${functions[_ui_render_one_message]}"
_ui_render_one_message() { (( rendered++ )); _fixture_render "$@"; }
UI_ACTIVE=1; SCREEN_H=60; SCREEN_W=200; SIDE_W=25
for (( i=1; i<=1000; i++ )); do
  ui_append_message assistant "Message $i: a retained conversation entry with enough text to exercise wrapping and cached layout."
done
ui_invalidate; ui_refresh_all
mapfile[$fixture_base.initial]="$rendered"
rendered=0; curses_calls=0; chat_paints=0
for (( i=1; i<=100; i++ )); do ui_refresh_all; done
mapfile[$fixture_base.idle]="$rendered:$curses_calls"
input_reset
for (( i=1; i<=20; i++ )); do ui_editor_input x ''; done
mapfile[$fixture_base.editing]="$rendered:$chat_paints:${#INPUT_BUF}"
ui_append_message assistant 'Streaming'
ui_draw_chat
rendered=0
for (( i=1; i<=25; i++ )); do
  UI_CONTENTS[-1]+=' next token'
  transcript_changed ${#UI_ROLES}
  ui_draw_chat
done
mapfile[$fixture_base.streaming]="$rendered:${#UI_ROLES}"
UI_FOCUS=chat; UI_AUTO_SCROLL=0; UI_SELECTED_EVENT=500; UI_SCROLL=0
rendered=0
ui_chat_input '' DOWN
mapfile[$fixture_base.selection]="$rendered:$UI_SELECTED_EVENT"
SCREEN_W=80; SIDE_W=0
ui_invalidate; ui_refresh_all
mapfile[$fixture_base.resize]="$rendered:$UI_SELECTED_EVENT"

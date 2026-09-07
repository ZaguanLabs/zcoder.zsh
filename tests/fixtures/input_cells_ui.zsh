#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile || exit 1
local_root="$1"; local_base="$2"
source "$local_root/lib/util.zsh"
source "$local_root/lib/transcript.zsh"
source "$local_root/lib/input.zsh"
source "$local_root/lib/terminal.zsh"
source "$local_root/lib/ui.zsh"
trap 'ui_end' EXIT
zcurses init || exit 1
UI_ACTIVE=1; SCREEN_W=10; INPUT_H=6; UI_FOCUS=input
zcurses addwin input_win 6 10 0 0 || exit 1
INPUT_BUF='界界界'; INPUT_POS=3
_ui_paint_input 1
zcurses refresh input_win
local -a cursor=() first=() second=()
zcurses position input_win cursor
zcurses move input_win 1 4; zcurses querychar input_win first
zcurses move input_win 2 4; zcurses querychar input_win second
mapfile[$local_base.wide]="${cursor[1]}:${cursor[2]}:${first[1]}:${second[1]}"
INPUT_BUF=$'a\u0301b'; INPUT_POS=3
_ui_paint_input 1
zcurses refresh input_win
zcurses position input_win cursor
mapfile[$local_base.combining]="${cursor[1]}:${cursor[2]}"
ui_end
mapfile[$local_base.done]=1

#!/usr/bin/env zsh
emulate -R zsh
typeset fixture_root=$1 fixture_base=$2
source "$fixture_root/lib/curses.zsh"
source "$fixture_root/lib/terminal.zsh"
ZCODER_CURSES=auto zcoder_curses_load "$fixture_root" || exit 1
zmodload zsh/mapfile zsh/datetime zsh/zselect || exit 1
typeset ZCODER_SYNC_OUTPUT=false
typeset ch='' key='' mouse=''
typeset -a before after
fixture_step() {
  local -F deadline=$(( EPOCHREALTIME + 8 ))
  mapfile[$fixture_base.step]=$1
  while [[ ${mapfile[$fixture_base.continue]:-} != $1 ]]; do
    (( EPOCHREALTIME < deadline )) || exit 2
    zselect -t 1
  done
}
command stty rows 24 cols 80 </dev/tty || exit 1
zcoder_curses init || exit 1
trap 'terminal_end; zcoder_curses end' EXIT
terminal_start
(( TERMINAL_NOREFRESH_INPUT )) || exit 3
zcoder_curses addwin child 2 30 5 0 || exit 1
zcoder_curses string stdscr BEFORE
terminal_refresh stdscr child
fixture_step ready
zcoder_curses move stdscr 1 0
zcoder_curses string stdscr SECRETFRAME
zcoder_curses string child HIDDENCHILD
zcoder_curses move stdscr 2 3
zcoder_curses position stdscr before
zcoder_curses timeout stdscr 100
zcoder_curses timeout child 100
terminal_read_event stdscr ch key mouse
[[ -z $ch$key$mouse ]] || exit 4
terminal_read_event child ch key mouse
[[ -z $ch$key$mouse ]] || exit 4
zcoder_curses position stdscr after
[[ "$before" == "$after" ]] || exit 5
fixture_step hidden
terminal_read_event child ch key mouse
[[ $ch == X && -z $key ]] || exit 6
terminal_read_event stdscr ch key mouse
[[ $key == UP && -z $ch ]] || exit 7
fixture_step stillhidden
command stty rows 30 cols 90 </dev/tty || exit 1
terminal_read_event child ch key mouse
[[ $key == RESIZE && -z $ch ]] || exit 8
fixture_step resized
terminal_refresh stdscr child
fixture_step presented
terminal_end
zcoder_curses end
zcoder_curses init || exit 1
terminal_start
(( TERMINAL_NOREFRESH_INPUT )) || exit 9
zcoder_curses timeout stdscr 0
terminal_read_event stdscr ch key mouse
terminal_end
(( ! TERMINAL_NOREFRESH_INPUT && ! ${#TERMINAL_EVENT_FLAGS} )) || exit 10
zcoder_curses end
trap - EXIT
mapfile[$fixture_base.step]=done

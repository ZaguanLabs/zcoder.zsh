#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/terminfo zsh/datetime zsh/mapfile || exit 1
typeset fixture_root=$1 fixture_base=$2 fixture_action=$3
source "$fixture_root/lib/curses.zsh"
ZCODER_CURSES=auto zcoder_curses_load "$fixture_root" || exit 1
for fixture_lib in util json transcript input terminal ui overlays commands command_dispatch; do
  source "$fixture_root/lib/$fixture_lib.zsh" || exit 1
done
typeset ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture
typeset ZCODER_WORKSPACE=$fixture_root OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset ZCODER_SYNC_OUTPUT=false ch='' key='' mouse='' leaked=''
typeset -i RUNNING=1
command stty rows 24 cols 80 < /dev/tty || exit 1
trap 'ui_end' EXIT
ui_init || exit 1
zcoder_curses timeout input_win 20
if (( ! TERMINAL_CAN_KEYBOARD )); then
  ui_end
  mapfile[$fixture_base/phase]=unsupported
  exit 0
fi
while [[ $TERMINAL_KEYBOARD_STATE == pending ]]; do
  terminal_read_event input_win ch key mouse
done
[[ $TERMINAL_KEYBOARD_STATE == supported ]] || exit 2
if [[ $fixture_action == resume ]]; then
  ui_suspend && ui_resume || exit 3
fi
mapfile[$fixture_base/phase]=ready
while (( RUNNING )); do
  terminal_read_event input_win ch key mouse
  if [[ $key == ENTER ]]; then
    handle_slash_command "$INPUT_BUF" || exit 4
  elif [[ -n $ch ]]; then
    INPUT_BUF+=$ch
  fi
done
[[ $INPUT_BUF == /quit ]] || exit 5
ui_end
# Stand in for the shell which regains the terminal after /quit. Do not flush
# pending input: the regression is precisely bytes escaping into this owner.
while read -r -k 1 -t 0.2 ch; do leaked+=$ch; done
mapfile[$fixture_base/leaked]=$leaked
mapfile[$fixture_base/phase]=done

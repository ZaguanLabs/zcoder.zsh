#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
typeset -g fixture_root="$1" fixture_base="$2"
source "$fixture_root/lib/curses.zsh"
ZCODER_CURSES=${3:-stock} zcoder_curses_load "$fixture_root" || exit 1
zmodload zsh/terminfo zsh/datetime zsh/mapfile || exit 1
for fixture_lib in util json transcript input terminal ui overlays commands; do
  source "$fixture_root/lib/${fixture_lib}.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture
typeset -g ZCODER_WORKSPACE="$fixture_root" OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_SYNC_OUTPUT=auto
command stty rows 24 cols 80 < /dev/tty || exit 1
trap 'ui_end' EXIT
functions[_fixture_approval_input]="${functions[_ui_approval_input]}"
_ui_approval_input() {
  _fixture_approval_input
  mapfile[${fixture_base}.approval]="${modal_done}:${TERMINAL_SYNC_STATE}"
}
ui_init || exit 1
mapfile[${fixture_base}.input]="$TERMINAL_NOREFRESH_INPUT"
ui_confirm_command 'This fixture only records the choice; it never runs commands.'
mapfile[${fixture_base}.answer]="$REPLY"
typeset -g fixture_ch='' fixture_key='' fixture_mouse=''
ui_activity_begin
while true; do
  zcoder_curses timeout input_win 50
  terminal_read_event input_win fixture_ch fixture_key fixture_mouse
  [[ "$fixture_ch" == $'\x07' ]] && break
  ui_activity_input "$fixture_ch" "$fixture_key"
  mapfile[${fixture_base}.draft]="$INPUT_BUF"
done
ui_activity_end
functions[_fixture_terminal_draw]="${functions[_ui_terminal_draw]}"
_ui_terminal_draw() {
  _fixture_terminal_draw
  mapfile[${fixture_base}.diagnostics]=1
}
ui_show_terminal
ui_end
mapfile[${fixture_base}.closed]="${TERMINAL_FD}:${TERMINAL_SYNC_ENABLED}:${TERMINAL_FRAME_ACTIVE}"

# Reentry reacquires the descriptor and modes. Each policy is tested on the
# same controlling terminal, without terminal-brand assumptions.
for ZCODER_SYNC_OUTPUT in false true invalid auto; do
  ui_init || exit 1
  if [[ "$ZCODER_SYNC_OUTPUT" == auto ]]; then
    TERMINAL_QUERY_DEADLINE=$(( EPOCHREALTIME - 1 ))
    terminal_poll
  fi
  mapfile[${fixture_base}.${ZCODER_SYNC_OUTPUT}]="$TERMINAL_SYNC_STATE:$TERMINAL_SYNC_ENABLED"
  ui_end
done
mapfile[${fixture_base}.done]=1

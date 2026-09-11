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
typeset fixture_tty_modes=$(command stty -g < /dev/tty)
trap 'ui_end' EXIT
functions[_fixture_approval_input]="${functions[_ui_approval_input]}"
_ui_approval_input() {
  _fixture_approval_input
  mapfile[${fixture_base}.approval]="${modal_done}:${TERMINAL_SYNC_STATE}"
  mapfile[${fixture_base}.approval_paste]="$modal_key:$modal_done:$TERMINAL_PASTE_BYTES"
  mapfile[${fixture_base}.approval_legacy_paste]="$TERMINAL_PASTE:$TERMINAL_PASTE_DISCARDING:$modal_done"
}
ui_init || exit 1
mapfile[${fixture_base}.input]="$TERMINAL_NOREFRESH_INPUT"
mapfile[${fixture_base}.native]="$TERMINAL_NATIVE_PASTE:$TERMINAL_EVENT_POLL"
mapfile[${fixture_base}.grapheme]="$INPUT_GRAPHEME"
ui_confirm_command 'This fixture only records the choice; it never runs commands.'
mapfile[${fixture_base}.answer]="$REPLY"
mapfile[${fixture_base}.sync]="$TERMINAL_NATIVE_QUERY:$TERMINAL_NATIVE_SYNC"
typeset -g fixture_ch='' fixture_key='' fixture_mouse=''
typeset -gi fixture_activity_done=0
functions[_fixture_activity_input]="${functions[ui_activity_input]}"
ui_activity_input() {
  fixture_ch=$1; fixture_key=$2
  [[ $fixture_ch == $'\x07' ]] && { fixture_activity_done=1; return 130; }
  _fixture_activity_input "$@"
  local -i result=$?
  mapfile[${fixture_base}.draft]="$INPUT_BUF"
  mapfile[${fixture_base}.cursor]="$INPUT_POS"
  mapfile[${fixture_base}.paste_bytes]="$TERMINAL_PASTE_BYTES"
  [[ $fixture_ch == $'\x03' ]] && mapfile[${fixture_base}.control]="cleared:${#INPUT_BUF}:$UI_FOCUS:$fixture_key:$INPUT_TERM_STATE"
  return "$result"
}
ui_activity_begin
while (( ! fixture_activity_done )); do
  ui_poll_activity || (( fixture_activity_done )) || exit 1
done
ui_activity_end
functions[ui_activity_input]="${functions[_fixture_activity_input]}"
functions[_fixture_terminal_draw]="${functions[_ui_terminal_draw]}"
_ui_terminal_draw() {
  _fixture_terminal_draw
  mapfile[${fixture_base}.diagnostic_lines]="${(F)modal_lines}"
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
    if (( TERMINAL_NATIVE_QUERY )); then
      # Native deadlines use a monotonic clock and are delivered as events.
      while [[ $TERMINAL_SYNC_STATE == pending ]]; do
        zcoder_curses timeout input_win 50
        terminal_read_event input_win fixture_ch fixture_key fixture_mouse
      done
    else
      TERMINAL_QUERY_DEADLINE=$(( EPOCHREALTIME - 1 ))
      terminal_poll
    fi
  fi
  mapfile[${fixture_base}.${ZCODER_SYNC_OUTPUT}]="$TERMINAL_SYNC_STATE:$TERMINAL_SYNC_ENABLED"
  ui_end
done
ui_init || exit 1
if (( TERMINAL_NATIVE_PASTE )); then
  mapfile[${fixture_base}.abandon]=ready
  while (( ! TERMINAL_PASTE_BYTES )); do
    zcoder_curses timeout input_win 50
    terminal_read_event input_win fixture_ch fixture_key fixture_mouse
  done
fi
ui_end
if [[ $(command stty -g < /dev/tty) == "$fixture_tty_modes" ]]; then
  mapfile[${fixture_base}.restored]=1
else
  mapfile[${fixture_base}.restored]=0
fi
mapfile[${fixture_base}.done]=1

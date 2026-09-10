#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
typeset fixture_root=$1 fixture_base=$2 fixture_mode=$3 fixture_action=$4
source "$fixture_root/lib/curses.zsh"
ZCODER_CURSES=$fixture_mode zcoder_curses_load "$fixture_root" || exit 1
zmodload zsh/terminfo zsh/datetime zsh/mapfile zsh/system || exit 1
for fixture_lib in util json transcript input terminal ui; do source "$fixture_root/lib/$fixture_lib.zsh"; done
typeset ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_SYNC_OUTPUT=true
typeset ZCODER_WORKSPACE=$fixture_root OLLAMA_HOST=fixture REMOTE_MODE=local ZCODER_PROFILE=coding
typeset -i fixture_inits=0 fixture_cancels=0 fixture_native=0 fixture_result=0 fixture_resumes=0
typeset fixture_modes='' ch='' key='' mouse=''
typeset -a reply=() probe=()
typeset -A row=()
command stty rows 24 cols 80 < /dev/tty || exit 1
fixture_modes=$(command stty -g < /dev/tty)
mapfile[$fixture_base.pid]=$sysparams[pid]
fixture_cleanup() {
  local -i result=$? restored=0
  ui_end
  [[ $(command stty -g < /dev/tty) == "$fixture_modes" ]] && restored=1
  mapfile[$fixture_base.closed]="$UI_ACTIVE:$UI_SUSPENDED:$restored"
  mapfile[$fixture_base.exit]=$result
  mapfile[$fixture_base.close_lifecycle]="$fixture_inits:$fixture_resumes"
}
trap fixture_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
agent_context_discovery_cancel() { (( fixture_cancels++ )); }
functions[_fixture_init]=$functions[ui_init]
ui_init() { (( fixture_inits++ )); _fixture_init; }
functions[_fixture_resume]=$functions[terminal_resume]
terminal_resume() { (( fixture_resumes++ )); _fixture_resume; }
functions[_fixture_copy]=$functions[_ui_copy_transcript]
_ui_copy_transcript() {
  local -i restored=0
  [[ $(command stty -g < /dev/tty) == "$fixture_modes" ]] && restored=1
  [[ $fixture_action == resize ]] && command stty rows 32 cols 100 < /dev/tty
  mapfile[$fixture_base.foreground]="$UI_ACTIVE:$UI_SUSPENDED:$restored"
  mapfile[$fixture_base.ready]=1
  _fixture_copy "$@"
}
INPUT_BUF=draft; INPUT_POS=5
ui_append_message assistant $'A copyable transcript\nwith a second line.'
ui_init || exit 1
zcoder_curses_features && (( ${reply[(Ie)suspend_resume]} )) && fixture_native=1
if (( fixture_native )); then
  zcoder_curses addwin retained_probe 1 12 6 0 || exit 2
  zcoder_curses prepare handoff_probe bold RETAINED || exit 2
  zcoder_curses draw retained_probe 0 0 handoff_probe || exit 2
fi
ui_copy_view
fixture_result=$?
mapfile[$fixture_base.result]=$fixture_result
mapfile[$fixture_base.lifecycle]="$fixture_inits:$fixture_cancels"
mapfile[$fixture_base.size]="$SCREEN_H:$SCREEN_W"
if (( fixture_native )); then
  if zcoder_curses position retained_probe probe && zcoder_curses rowinfo handoff_probe row &&
     [[ $row[width] == 8 ]]; then
    mapfile[$fixture_base.retained]=1
  fi
fi
(( UI_ACTIVE && ! UI_SUSPENDED )) || exit 3
mapfile[$fixture_base.resumed]=1
while [[ $INPUT_BUF != 'draft post' ]]; do
  zcoder_curses timeout input_win 50
  terminal_read_event input_win ch key mouse
  if input_decode_terminal_event "$ch" "$key" && [[ $INPUT_EVENT_ACTION == paste ]]; then
    input_insert "$INPUT_EVENT_TEXT"
  fi
done
mapfile[$fixture_base.pasted]=$INPUT_BUF
exit 0

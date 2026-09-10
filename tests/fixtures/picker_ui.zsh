#!/usr/bin/env zsh
# Actual picker input/resize plus deterministic retained-cell captures.
emulate -R zsh
setopt extendedglob
zmodload zsh/terminfo zsh/datetime zsh/mapfile || exit 1
typeset -g fixture_root=$1 fixture_base=$2 fixture_backend=$3
source "$fixture_root/lib/curses.zsh"
ZCODER_CURSES=$fixture_backend zcoder_curses_load "$fixture_root" || exit 1
for fixture_lib in util json transcript input terminal ui overlays; do
  source "$fixture_root/lib/$fixture_lib.zsh" || exit 1
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=alpha
typeset -g ZCODER_WORKSPACE=$fixture_root OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_SYNC_OUTPUT=false ZCODER_COMMAND_POLICY=ask
typeset -gi STATE_ENABLED=0 fixture_capture=0
typeset -g fixture_phase=choose fixture_last='' zdraw_ui_fixture
typeset -a models=(alpha 'beta model' '界 é model')
for fixture_index in {4..30}; do models+=("model-$fixture_index"); done
if [[ $ZCODER_CURSES_COMMAND == zdraw ]]; then
  source "$fixture_root/vendor/zdraw/lib/zdraw-fixture.zsh" || exit 1
  (( ${zdraw_features[(Ie)window_snapshots]} )) && fixture_capture=1
fi
functions[_fixture_picker_draw]=${functions[_ui_modal_list_draw]}
_ui_modal_list_draw() {
  _fixture_picker_draw || return
  local frame="$fixture_phase:$modal_selected:$SCREEN_W"
  if [[ $frame != "$fixture_last" ]]; then
    if (( fixture_capture )); then
      zdraw-fixture overlay_win || exit 10
      print -r -- "$zdraw_ui_fixture" > "$fixture_base-$fixture_phase-$modal_selected-$SCREEN_W.json"
    fi
    mapfile[$fixture_base.widgets]=${modal_picker_widgets:-0}
    mapfile[$fixture_base.frame]=$frame
    fixture_last=$frame
  fi
}
command stty rows 12 cols 44 </dev/tty || exit 1
trap 'ui_end' EXIT
INPUT_BUF='unfinished prompt'; INPUT_POS=6
ui_init || exit 1
mapfile[$fixture_base.tty]=$TTY
mapfile[$fixture_base.backend]=$ZCODER_CURSES_COMMAND
ui_modal_choose Models alpha "${models[@]}" || exit 2
[[ $REPLY == 2 && $models[REPLY] == 'beta model' ]] || exit 3
fixture_phase=empty
ui_modal_choose Models '' && exit 4
[[ -z $REPLY ]] || exit 5
# Exercise a failure after the toolkit has already changed retained cells.
fixture_phase=fallback
functions[_fixture_native_picker]=${functions[_ui_picker_draw]}
_ui_picker_draw() {
  zdraw fill overlay_win 1 1 2 10 '' X
  return 1
}
ui_modal_choose Models alpha "${models[@]}" || exit 6
[[ $REPLY == 1 ]] || exit 7
functions[_ui_picker_draw]=${functions[_fixture_native_picker]}
fixture_phase=unusual
typeset -a unusual_models=(alpha $'beta\n\e[31m $(print injected)' $'\u0301leading')
ui_modal_choose Models alpha "${unusual_models[@]}" || exit 9
[[ $REPLY == 2 && $unusual_models[REPLY] == $'beta\n\e[31m $(print injected)' ]] || exit 11
[[ $INPUT_BUF == 'unfinished prompt' && $INPUT_POS == 6 && $UI_MODAL_ACTIVE == 0 ]] || exit 8
ui_end
mapfile[$fixture_base.done]=1

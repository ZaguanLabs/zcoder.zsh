#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/terminfo zsh/datetime zsh/mapfile || exit 1
typeset -g fixture_root=$1 fixture_base=$2 fixture_backend=$3
source "$fixture_root/lib/curses.zsh"
ZCODER_CURSES=$fixture_backend zcoder_curses_load "$fixture_root" || exit 1
for fixture_lib in util json transcript input terminal ui overlays commands; do
  source "$fixture_root/lib/$fixture_lib.zsh" || exit 1
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=alpha
typeset -g ZCODER_WORKSPACE=$fixture_root OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_SYNC_OUTPUT=false ZCODER_COMMAND_POLICY=ask
typeset -gi STATE_ENABLED=0 fixture_capture=0 fixture_draws=0
typeset -g fixture_phase=reader zdraw_ui_fixture
typeset -g prose='Keep this paragraph visible while resizing the terminal. Its source position should survive wrapping. '
prose="${(pr:1600::$prose:)}"
if [[ $ZCODER_CURSES_COMMAND == zdraw ]]; then
  source "$fixture_root/vendor/zdraw/lib/zdraw-fixture.zsh" || exit 1
  (( ${zdraw_features[(Ie)window_snapshots]} )) && fixture_capture=1
fi
functions[_fixture_document_draw]=${functions[_ui_document_draw]}
_ui_document_draw() {
  _fixture_document_draw || return
  local -i block=${document_line_blocks[modal_selected]:-0}
  local block_id=${document_blocks[block*3-2]}
  if [[ $fixture_phase == help && $block_id == tools ]]; then fixture_phase=tools; fi
  mapfile[$fixture_base.block_id]=$block_id
  if (( document_native )); then
    mapfile[$fixture_base.anchor]="$block:$zdraw_ui_document[$modal_selected,byte_start]:$zdraw_ui_document[$modal_selected,byte_end]"
  else
    mapfile[$fixture_base.anchor]="$block:0:0"
  fi
  if (( fixture_capture )) && [[ $fixture_phase != large ]]; then
    zdraw-fixture overlay_win || exit 10
    print -r -- "$zdraw_ui_fixture" > "$fixture_base-$fixture_phase-$SCREEN_W.json"
  fi
  mapfile[$fixture_base.native]=$document_native
  mapfile[$fixture_base.block]=$block
  mapfile[$fixture_base.width]=$SCREEN_W
  mapfile[$fixture_base.first]=$modal_selected
  (( fixture_draws++ ))
  mapfile[$fixture_base.draws]=$fixture_draws
  mapfile[$fixture_base.phase]=$fixture_phase
}
command stty rows 12 cols 44 </dev/tty || exit 1
trap 'ui_end' EXIT
INPUT_BUF='unfinished prompt'; INPUT_POS=6
ui_append_message user 'Original conversation'
ui_init || exit 1
mapfile[$fixture_base.tty]=$TTY
mapfile[$fixture_base.backend]=$ZCODER_CURSES_COMMAND
ui_document_view Reader intro heading Introduction first paragraph "$prose" \
  editing heading Editing second paragraph "$prose" \
  ending heading 'More information' last paragraph 'End of document.' || exit 2
fixture_phase=help
ui_show_help 'Codex is available.' || exit 3
(( ${#UI_ROLES} == 1 )) || exit 4
fixture_phase=fallback
functions[_fixture_native_document]=${functions[zdraw-document]}
zdraw-document() { zdraw fill overlay_win 2 2 2 10 '' X; return 1; }
ui_document_view 'Draw failure' heading heading 'Still readable' body paragraph 'A failed draw keeps all the text.' || exit 5
functions[zdraw-document]=${functions[_fixture_native_document]}
fixture_phase=large
ui_document_view Large heading heading 'Large source' body paragraph "${(pl:33000::x:)}" || exit 6
[[ $INPUT_BUF == 'unfinished prompt' && $INPUT_POS == 6 && $UI_MODAL_ACTIVE == 0 ]] || exit 7
ui_end
mapfile[$fixture_base.done]=1

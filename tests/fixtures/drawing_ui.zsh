#!/usr/bin/env zsh
# Capture real retained cells and exercise both drawing paths in a private PTY.
emulate -R zsh
setopt extendedglob
typeset -g fixture_root=$1 fixture_base=$2 fixture_backend=$3
source "$fixture_root/lib/curses.zsh"
ZCODER_CURSES=$fixture_backend zcoder_curses_load "$fixture_root" || exit 1
zmodload zsh/terminfo zsh/datetime zsh/mapfile || exit 1
for fixture_lib in util json transcript agent input terminal ui; do
  source "$fixture_root/lib/$fixture_lib.zsh"
done
typeset -g ZCODER_NAME=zcoder.zsh ZCODER_VERSION=preview ZCODER_MODEL=qwen3-coder
typeset -g ZCODER_WORKSPACE=$fixture_root OLLAMA_HOST=localhost:11434 ZCODER_PROFILE=coding
typeset -g REMOTE_MODE=local ZCODER_SYNC_OUTPUT=false
typeset -g ZCODER_COMMAND_POLICY=ask CURRENT_SESSION_ID=preview
typeset -a SESSION_IDS=(preview earlier) SESSION_TITLES=('Rendering refresh' 'Review tool output')
typeset -a SESSION_MODELS=(qwen3-coder qwen3-coder)
typeset -g INPUT_BUF='Explain the fallback for combining characters.'
typeset -gi INPUT_POS=${#INPUT_BUF}
command stty rows 30 cols 110 </dev/tty || exit 1
trap 'ui_end' EXIT
ui_append_message user 'Make the terminal interface easier to read.'
ui_append_message assistant 'The renderer now uses a coordinated palette and rounded borders.'
transcript_tool_event begin write_file '{"path":"render.zsh","content":"render_row() {\n  local message=\"Hello, terminal\"\n  print -r -- \"$message\"\n}"}'
transcript_tool_event complete write_file '{}' 'Wrote render.zsh' 1
UI_BLOCK_OPEN[${#UI_ROLES}]=1
ui_append_message assistant 'Styled rows keep keyboard input and refresh ownership unchanged.'
ui_set_status Ready
ui_init || exit 1
(( ${#UI_SEGMENT_TEXTS} > 0 )) || exit 6
mapfile[$fixture_base.mode]="$UI_COLOR_MODE:$UI_BORDER_MODE:$UI_STYLED_SPANS"
mapfile[$fixture_base.rgb]="${UI_COLOR_INFO[truecolor_supported]:-0}"
typeset -i row col
typeset -a cell before after
typeset -a fixture_spans=('bold cyan/black' 'const ' 'magenta/black' 'value ' 'white/black' '= ' 'yellow/black' '"hello"' 'white/black' '        ')
zcurses addwin sample 3 50 0 0 || exit 1
ui_window_background sample
UI_STYLED_SPANS=0
ui_draw_row sample 1 1 "${fixture_spans[@]}"
for ((col=1; col<28; col++)); do
  zcurses move sample 1 $col
  zcurses querychar sample cell || exit 1
  before+=("${(j: :)cell}")
done
zcurses clear sample
[[ $fixture_backend == auto ]] && UI_STYLED_SPANS=1
ui_draw_row sample 1 1 "${fixture_spans[@]}"
for ((col=1; col<28; col++)); do
  zcurses move sample 1 $col
  zcurses querychar sample cell || exit 1
  after+=("${(j: :)cell}")
done
[[ "${(j:|:)before}" == "${(j:|:)after}" ]] || exit 2
mapfile[$fixture_base.equivalent]=1
if [[ $fixture_backend == auto ]]; then
  # A syntax boundary can leave a combining mark at the start of a span.
  # The batch must reject it; the existing renderer still displays the row.
  ui_draw_row sample 1 1 'white/black' e 'white/black' $'\u0301' 'green/black' Z
  (( UI_SPAN_FALLBACKS == 1 )) || exit 3
  zcurses move sample 1 1
  zcurses querychar sample cell || exit 1
  [[ $cell[1] == e ]] || exit 4
  zcurses move sample 1 2
  zcurses querychar sample cell || exit 1
  [[ $cell[1] == Z ]] || exit 5
  mapfile[$fixture_base.fallback]=1
fi
zcurses delwin sample
ui_invalidate
ui_refresh_all
# Export the actual curses cells, including resolved pair spelling, for visual QA.
typeset window out='' ch pair x y
typeset -a geometry
for window in top_win side_win chat_win input_win foot_win; do
  zcurses position "$window" geometry || exit 1
  for ((row=0; row<geometry[5]; row++)); do
    for ((col=0; col<geometry[6]; col++)); do
      zcurses move "$window" $row $col
      zcurses querychar "$window" cell || exit 1
      x=$(( geometry[4]+col )); y=$(( geometry[3]+row ))
      out+="$x"$'\t'"$y"$'\t'"$cell[2]"$'\t'"$cell[1]"$'\n'
    done
  done
done
mapfile[$fixture_base.cells]="$out"
ui_end
mapfile[$fixture_base.done]=1
